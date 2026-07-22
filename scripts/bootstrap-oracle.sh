#!/usr/bin/env bash
set -euo pipefail

# Bootstrap helper for Oracle Cloud Infrastructure (OCI) compute instances.
#
# Oracle's Ubuntu images ship with a locked-down iptables/netfilter-persistent
# ruleset that drops most inbound traffic, even after you open ports in the OCI
# Security List. This script clears those instance-level blocks, applies host
# firewall rules that fit the Tailscale-first design, then hands off to the
# normal install-tailscale.sh + setup-apps.sh flow.

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script must be run on the Oracle Cloud (Ubuntu) server."
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

RAW_BASE="${VPS_INFRA_RAW_BASE:-https://raw.githubusercontent.com/bongnv/vps-infra/main}"

# SSH is the only inbound port opened publicly. Everything else (Portainer,
# app stacks) is reached over the Tailscale interface, and public apps use an
# outbound-only Cloudflare Tunnel, so no other inbound ports are ever exposed.
SSH_PORT="${SSH_PORT:-22}"

run_local_or_remote() {
  local script_name script_source script_dir
  script_name="${1}"
  script_source="${BASH_SOURCE[0]:-}"

  if [[ -n "${script_source}" && "${script_source}" != "bash" && -f "${script_source}" ]]; then
    script_dir="$(cd -- "$(dirname -- "${script_source}")" && pwd)"
    if [[ -x "${script_dir}/${script_name}" ]]; then
      "${script_dir}/${script_name}"
      return
    fi
  fi

  curl -fsSL "${RAW_BASE}/scripts/${script_name}" | bash
}

install_base_packages() {
  echo "==> Installing package prerequisites"
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y ca-certificates curl gnupg iptables
}

clear_oracle_iptables() {
  echo "==> Clearing Oracle's default instance-level iptables rules"

  # Oracle ships restrictive rules that REJECT most inbound traffic. Flush the
  # filter table and set permissive defaults; the OCI Security List (VCN level)
  # plus UFW below provide the real access control.
  ${SUDO} iptables -P INPUT ACCEPT
  ${SUDO} iptables -P FORWARD ACCEPT
  ${SUDO} iptables -P OUTPUT ACCEPT
  ${SUDO} iptables -F
  ${SUDO} iptables -X 2>/dev/null || true

  if command -v ip6tables >/dev/null 2>&1; then
    ${SUDO} ip6tables -P INPUT ACCEPT
    ${SUDO} ip6tables -P FORWARD ACCEPT
    ${SUDO} ip6tables -P OUTPUT ACCEPT
    ${SUDO} ip6tables -F
    ${SUDO} ip6tables -X 2>/dev/null || true
  fi

  # Persist the cleared state so it survives reboots. Oracle uses
  # netfilter-persistent; if it is not present, disabling it is a no-op.
  if command -v netfilter-persistent >/dev/null 2>&1; then
    echo "==> Persisting cleared iptables via netfilter-persistent"
    ${SUDO} netfilter-persistent save || true
  fi
}

configure_ufw() {
  echo "==> Configuring UFW host firewall"
  ${SUDO} apt-get install -y ufw

  ${SUDO} ufw --force reset
  ${SUDO} ufw default deny incoming
  ${SUDO} ufw default allow outgoing

  echo "==> Allowing SSH on port ${SSH_PORT}"
  ${SUDO} ufw allow "${SSH_PORT}/tcp"

  # Allow all traffic on the Tailscale interface so app ports stay reachable
  # privately without being exposed to the public internet.
  echo "==> Allowing traffic on the tailscale0 interface"
  ${SUDO} ufw allow in on tailscale0

  ${SUDO} ufw --force enable
  ${SUDO} ufw status verbose || true
}

print_summary() {
  echo
  echo "Oracle Cloud bootstrap complete."
  echo
  echo "What this did:"
  echo "1. Cleared Oracle's restrictive instance-level iptables rules."
  echo "2. Applied a UFW host firewall (SSH open, apps via Tailscale)."
  echo "3. Ran the Tailscale and apps stages (Docker, Portainer, HTTPS Serve)."
  echo
  echo "Reminder: open only the SSH ingress rule in the OCI Security List."
  echo "No other inbound ports are needed (apps use Tailscale / Cloudflare Tunnel)."
}

install_base_packages
clear_oracle_iptables

echo
echo "==> Running Tailscale setup stage"
run_local_or_remote "install-tailscale.sh"

# UFW references tailscale0, which only exists after Tailscale is up.
configure_ufw

echo
echo "==> Running apps setup stage"
run_local_or_remote "setup-apps.sh"

print_summary
