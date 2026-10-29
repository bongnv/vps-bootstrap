#!/usr/bin/env bash
set -euo pipefail

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
fi

fail() {
  echo "Error: $*" >&2
  exit 1
}

case "${ENABLE_TAILSCALE_SSH:-false}" in
  true|false) ;;
  *) fail "ENABLE_TAILSCALE_SSH must be true or false." ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
installer="${script_dir}/install-tailscale.sh"
download=""
trap 'if [[ -n "${download}" ]]; then rm -f -- "${download}"; fi' EXIT

if [[ ! -f "${installer}" ]]; then
  command -v curl >/dev/null || fail "curl is required to download the installer."
  download="$(mktemp)"
  curl -fsSL "${VPS_INFRA_RAW_BASE:-https://raw.githubusercontent.com/bongnv/vps-bootstrap/main}/scripts/install-tailscale.sh" \
    -o "${download}"
  installer="${download}"
fi

ENABLE_TAILSCALE_SSH="${ENABLE_TAILSCALE_SSH:-false}" bash "${installer}"

status="$(${SUDO} tailscale status --json)" || fail "Cannot read Tailscale status. Check login and machine approval."
grep -qE '"BackendState"[[:space:]]*:[[:space:]]*"Running"' <<<"${status}" || \
  fail "Tailscale is not connected. Complete login or machine approval and rerun."

command -v sysctl >/dev/null || fail "sysctl is required. Install the Ubuntu procps package."
[[ "$(${SUDO} sysctl -n net.ipv6.conf.all.disable_ipv6)" == "0" ]] || \
  fail "Enable IPv6 in the kernel before configuring this exit node."

sysctl_file="/etc/sysctl.d/99-tailscale-exit-node.conf"
{
  echo "# Managed by setup-tailscale-exit-node.sh"
  # Keep receiving IPv6 router advertisements after enabling forwarding.
  for path in /proc/sys/net/ipv6/conf/*/accept_ra; do
    [[ -r "${path}" ]] || continue
    read -r value <"${path}"
    if [[ "${value}" == "1" || "${value}" == "2" ]]; then
      interface="${path%/accept_ra}"
      printf 'net/ipv6/conf/%s/accept_ra = 2\n' "${interface##*/}"
    fi
  done
  echo "net.ipv4.ip_forward = 1"
  echo "net.ipv6.conf.all.forwarding = 1"
} | ${SUDO} tee "${sysctl_file}" >/dev/null
${SUDO} sysctl -p "${sysctl_file}"

args=(set --advertise-exit-node --netfilter-mode=on --snat-subnet-routes=true)
if [[ -n "${TAILSCALE_HOSTNAME:-}" ]]; then
  args+=("--hostname=${TAILSCALE_HOSTNAME}")
fi
if [[ -n "${ENABLE_TAILSCALE_SSH:-}" ]]; then
  args+=("--ssh=${ENABLE_TAILSCALE_SSH}")
fi
${SUDO} tailscale "${args[@]}"

address="$(${SUDO} tailscale ip -4)"
cat <<EOF

Local setup complete. Approve Use as exit node for ${address} at:
https://login.tailscale.com/admin/machines

On a Linux client, select this server with:
  sudo tailscale set --exit-node=${address}
Then verify the client's public IP matches this server's public IP.
Existing host and cloud firewall rules were not changed.
EOF
