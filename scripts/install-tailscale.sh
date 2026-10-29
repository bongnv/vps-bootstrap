#!/usr/bin/env bash
set -euo pipefail

prepare_host() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This script must be run on the Ubuntu server."
    exit 1
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi

  if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "This script is intended for Ubuntu Server. Detected: ${PRETTY_NAME:-unknown}"
    exit 1
  fi

  SUDO=""
  if [[ "${EUID}" -ne 0 ]]; then
    SUDO="sudo"
  fi

  TARGET_USER="${SUDO_USER:-${USER:-root}}"
  RAW_BASE="${VPS_INFRA_RAW_BASE:-https://raw.githubusercontent.com/bongnv/vps-infra/main}"
}

install_base_packages() {
  echo "==> Installing SSH and package prerequisites"
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y ca-certificates curl gnupg openssh-server
  ${SUDO} systemctl enable --now ssh
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    echo "==> Tailscale is already installed"
  else
    echo "==> Installing Tailscale from Tailscale's apt repository"
    local codename
    codename="${VERSION_CODENAME:-}"

    if [[ -z "${codename}" ]]; then
      echo "Could not detect Ubuntu codename from /etc/os-release."
      exit 1
    fi

    ${SUDO} install -m 0755 -d /usr/share/keyrings
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" | \
      ${SUDO} tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" | \
      ${SUDO} tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    ${SUDO} apt-get update
    ${SUDO} apt-get install -y tailscale
  fi

  echo "==> Enabling Tailscale"
  ${SUDO} systemctl enable --now tailscaled
}

has_terminal() {
  ( : </dev/tty ) 2>/dev/null
}

prompt_authkey() {
  echo "==> Paste Tailscale auth key, or press Enter for browser login:" >/dev/tty
  IFS= read -r -s TAILSCALE_AUTHKEY </dev/tty || true
  echo >/dev/tty
}

connect_tailscale() (
  local tailscale_hostname tailscale_ssh_arg status auth_key_file
  tailscale_hostname="${TAILSCALE_HOSTNAME:-$(hostname -s 2>/dev/null || echo macbook-home)}"
  tailscale_ssh_arg=""

  if [[ "${ENABLE_TAILSCALE_SSH:-true}" == "true" ]]; then
    tailscale_ssh_arg="--ssh"
  fi

  status="$(${SUDO} tailscale status --json 2>/dev/null)" || true
  if grep -qE '"BackendState"[[:space:]]*:[[:space:]]*"Running"' <<<"${status}"; then
    echo "==> Tailscale is already connected"
    return
  fi

  if [[ -z "${TAILSCALE_AUTHKEY:-}" ]] && has_terminal; then
    prompt_authkey
  fi

  echo "==> Connecting Tailscale"
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    auth_key_file="$(umask 077; mktemp)"
    trap 'rm -f -- "${auth_key_file}"' EXIT
    printf '%s' "${TAILSCALE_AUTHKEY}" >"${auth_key_file}"
    unset TAILSCALE_AUTHKEY
    ${SUDO} tailscale up \
      --hostname="${tailscale_hostname}" \
      --auth-key="file:${auth_key_file}" \
      ${tailscale_ssh_arg} \
      ${TAILSCALE_EXTRA_ARGS:-}
  elif has_terminal; then
    ${SUDO} tailscale up \
      --hostname="${tailscale_hostname}" \
      ${tailscale_ssh_arg} \
      ${TAILSCALE_EXTRA_ARGS:-}
  else
    echo "==> TAILSCALE_AUTHKEY not set and no TTY is available; skipping tailscale up"
    echo "    Re-run on the server with: sudo tailscale up --hostname=${tailscale_hostname}"
  fi
)

print_summary() {
  local tailscale_hostname tailscale_ip
  tailscale_hostname="${TAILSCALE_HOSTNAME:-$(hostname -s 2>/dev/null || echo macbook-home)}"
  tailscale_ip="$(${SUDO} tailscale ip -4 2>/dev/null | head -n 1 || true)"

  echo
  echo "Tailscale setup complete."
  echo
  echo "Next step: SSH from another device that is signed in to the same tailnet."
  if [[ -n "${tailscale_ip}" ]]; then
    echo "ssh ${TARGET_USER}@${tailscale_ip}"
  fi
  echo "ssh ${TARGET_USER}@${tailscale_hostname}"
  echo
  echo "After SSH works, run one of these from the SSH session:"
  echo "  Portainer host:  curl -fsSL ${RAW_BASE}/scripts/setup-portainer-host.sh | bash"
  echo "  Portainer agent: curl -fsSL ${RAW_BASE}/scripts/setup-portainer-agent.sh | bash"
}

main() {
  prepare_host
  install_base_packages
  install_tailscale
  connect_tailscale
  print_summary
}

if [[ "${BASH_SOURCE[0]:-${0}}" == "${0}" ]]; then
  main "$@"
fi
