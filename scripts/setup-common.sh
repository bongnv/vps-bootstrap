#!/usr/bin/env bash
set -euo pipefail

# Shared host setup for both Portainer roles: installs Docker Engine and the
# Compose plugin, and applies the UFW firewall baseline. Safe to run on its own,
# and re-running it is idempotent. The Portainer host/agent scripts call this
# automatically if Docker is not yet installed.

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

# Host firewall baseline. SSH is the only publicly allowed inbound port;
# everything else (Portainer, agent, app stacks) is reached over the Tailscale
# interface. Set ENABLE_UFW=false to skip firewall configuration.
ENABLE_UFW="${ENABLE_UFW:-true}"
SSH_PORT="${SSH_PORT:-22}"

install_base_packages() {
  echo "==> Installing package prerequisites"
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y ca-certificates curl git gnupg
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "==> Docker and Docker Compose plugin are already installed"
  else
    echo "==> Installing Docker Engine from Docker's apt repository"
    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="${VERSION_CODENAME:-}"

    if [[ -z "${codename}" ]]; then
      echo "Could not detect Ubuntu codename from /etc/os-release."
      exit 1
    fi

    ${SUDO} install -m 0755 -d /etc/apt/keyrings
    ${SUDO} curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    ${SUDO} chmod a+r /etc/apt/keyrings/docker.asc

    ${SUDO} tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    ${SUDO} apt-get update
    ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  echo "==> Enabling Docker"
  ${SUDO} systemctl enable --now docker

  if [[ "${TARGET_USER}" != "root" ]]; then
    echo "==> Adding ${TARGET_USER} to the docker group"
    ${SUDO} usermod -aG docker "${TARGET_USER}"
  fi
}

configure_ufw() {
  if [[ "${ENABLE_UFW}" != "true" ]]; then
    return
  fi

  echo "==> Configuring UFW host firewall"
  ${SUDO} apt-get install -y ufw

  ${SUDO} ufw --force reset
  ${SUDO} ufw default deny incoming
  ${SUDO} ufw default allow outgoing

  echo "==> Allowing SSH on port ${SSH_PORT}"
  ${SUDO} ufw allow "${SSH_PORT}/tcp"

  # Allow all traffic on the Tailscale interface so Portainer, the agent, and
  # app stacks stay reachable privately without being exposed to the internet.
  if ip link show tailscale0 >/dev/null 2>&1; then
    echo "==> Allowing traffic on the tailscale0 interface"
    ${SUDO} ufw allow in on tailscale0
  else
    echo "==> tailscale0 interface not found; run install-tailscale.sh first for private access"
  fi

  ${SUDO} ufw --force enable
  ${SUDO} ufw status verbose || true
}

# Allow this file to be sourced (functions only) without running the steps.
if [[ "${SETUP_COMMON_SOURCE_ONLY:-false}" != "true" ]]; then
  install_base_packages
  install_docker
  configure_ufw
fi
