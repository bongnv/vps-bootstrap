#!/usr/bin/env bash
set -euo pipefail

SUDO=""
SYSCTL_FILE="/etc/sysctl.d/99-tailscale-exit-node.conf"
INSTALLER_FILE=""

fail() {
  echo "Error: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${INSTALLER_FILE}" ]]; then
    rm -f -- "${INSTALLER_FILE}"
  fi
}

preflight() {
  [[ "$(uname -s)" == "Linux" ]] || fail "Run this script on Ubuntu Server."
  [[ -r /etc/os-release ]] || fail "Cannot read /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" && -n "${VERSION_CODENAME:-}" ]] || \
    fail "Ubuntu Server with a release codename is required."
  [[ -d /run/systemd/system ]] || fail "A server running systemd is required."
  case "${ENABLE_TAILSCALE_SSH:-false}" in
    true|false) ;;
    *) fail "ENABLE_TAILSCALE_SSH must be true or false." ;;
  esac
  if [[ "${EUID}" -ne 0 ]]; then
    command -v sudo >/dev/null || fail "Run as root or install sudo."
    SUDO="sudo"
    sudo -v
  fi
}

run_installer() {
  local script_dir installer
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  installer="${script_dir}/install-tailscale.sh"
  if [[ ! -f "${installer}" ]]; then
    echo "==> Downloading the shared Tailscale installer"
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y ca-certificates curl
    INSTALLER_FILE="$(mktemp)"
    curl -fsSL "${VPS_INFRA_RAW_BASE:-https://raw.githubusercontent.com/bongnv/vps-bootstrap/main}/scripts/install-tailscale.sh" \
      -o "${INSTALLER_FILE}"
    installer="${INSTALLER_FILE}"
  fi
  # The shared installer owns installation and login, but not exit node settings.
  ENABLE_TAILSCALE_SSH="${ENABLE_TAILSCALE_SSH:-false}" bash "${installer}"
  cleanup
  INSTALLER_FILE=""
  ${SUDO} apt-get install -y python3 procps
}

backend_state() {
  local status
  # The status command can return nonzero while logged out, but still emit JSON.
  status="$(${SUDO} tailscale status --json 2>/dev/null)" || true
  printf '%s' "${status}" | python3 -c \
    'import json, sys; print(json.load(sys.stdin)["BackendState"])'
}

verify_connection() {
  local state
  state="$(backend_state)" || fail "Cannot read Tailscale state. Check tailscaled."
  [[ "${state}" == "Running" ]] || \
    fail "Tailscale is not running (${state}). Complete login or machine approval, then rerun."
}

ipv6_ra_settings() {
  local path value interface
  # Preserve router advertisements when forwarding turns this host into a router.
  for path in /proc/sys/net/ipv6/conf/*/accept_ra; do
    [[ -r "${path}" ]] || continue
    value="$(cat "${path}")"
    if [[ "${value}" == "1" || "${value}" == "2" ]]; then
      interface="${path%/accept_ra}"
      interface="${interface##*/}"
      printf 'net/ipv6/conf/%s/accept_ra = 2\n' "${interface}"
    fi
  done
}

configure_forwarding() {
  [[ "$(${SUDO} sysctl -n net.ipv6.conf.all.disable_ipv6)" == "0" ]] || \
    fail "IPv6 is disabled. Enable it before configuring this exit node."
  echo "==> Enabling persistent IP forwarding"
  ${SUDO} install -m 0755 -d /etc/sysctl.d
  {
    echo "# Managed by setup-tailscale-exit-node.sh"
    ipv6_ra_settings
    echo "net.ipv4.ip_forward = 1"
    echo "net.ipv6.conf.all.forwarding = 1"
  } | ${SUDO} tee "${SYSCTL_FILE}" >/dev/null
  ${SUDO} sysctl -p "${SYSCTL_FILE}"
  [[ "$(${SUDO} sysctl -n net.ipv4.ip_forward)" == "1" && \
     "$(${SUDO} sysctl -n net.ipv6.conf.all.forwarding)" == "1" ]] || \
    fail "IP forwarding verification failed."
}

advertise_exit_node() {
  local args=(set --advertise-exit-node --netfilter-mode=on --snat-subnet-routes=true)
  if [[ -n "${TAILSCALE_HOSTNAME:-}" ]]; then
    args+=("--hostname=${TAILSCALE_HOSTNAME}")
  fi
  if [[ -n "${ENABLE_TAILSCALE_SSH:-}" ]]; then
    args+=("--ssh=${ENABLE_TAILSCALE_SSH}")
  fi
  echo "==> Advertising this server as an exit node"
  ${SUDO} tailscale "${args[@]}"
}

print_summary() {
  local address
  address="$(${SUDO} tailscale ip -4)"
  [[ -n "${address}" ]] || fail "No Tailscale IPv4 address was assigned."
  cat <<EOF

Local exit node configuration complete. Admin approval and client testing remain.

1. Open https://login.tailscale.com/admin/machines
   Find ${address}, open Edit route settings, and approve Use as exit node.
   Tailnet policy must allow the intended clients to use internet routes.
2. Select this server in a client's Tailscale Exit Node menu, or on Linux run:
   sudo tailscale set --exit-node=${address}
3. On that client, verify its public IP matches this server's public IP:
   curl -4 https://ifconfig.me
   Compare IPv6 too if the server has upstream IPv6 connectivity:
   curl -6 https://ifconfig.me

Existing host and cloud firewall rules were not reset or opened.
Tailscale manages forwarding and NAT through its netfilter rules.
If client traffic fails, check host and cloud firewall forwarding rules.
Keep your existing SSH session open until client connectivity is verified.
EOF
}

main() {
  trap cleanup EXIT
  preflight
  run_installer
  verify_connection
  configure_forwarding
  advertise_exit_node
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
