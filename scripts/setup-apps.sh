#!/usr/bin/env bash
set -euo pipefail

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
INSTALL_DIR="${INSTALL_DIR:-/opt/vps-infra}"
RAW_BASE="${VPS_INFRA_RAW_BASE:-https://raw.githubusercontent.com/bongnv/vps-infra/main}"
COMPOSE_FILE="${COMPOSE_FILE:-}"
ENV_FILE="${ENV_FILE:-}"

install_base_packages() {
  echo "==> Installing package prerequisites"
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y ca-certificates curl git gnupg
}

resolve_compose_file() {
  if [[ -n "${COMPOSE_FILE}" ]]; then
    echo "==> Using compose file: ${COMPOSE_FILE}"
    return
  fi

  local script_source script_dir repo_dir local_compose
  script_source="${BASH_SOURCE[0]:-}"

  if [[ -n "${script_source}" && "${script_source}" != "bash" && -f "${script_source}" ]]; then
    script_dir="$(cd -- "$(dirname -- "${script_source}")" && pwd)"
    repo_dir="$(cd -- "${script_dir}/.." && pwd)"
    local_compose="${repo_dir}/docker-compose.yml"

    if [[ -f "${local_compose}" ]]; then
      COMPOSE_FILE="${local_compose}"
      echo "==> Using local compose file: ${COMPOSE_FILE}"
      return
    fi
  fi

  COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
  echo "==> Downloading compose file to ${COMPOSE_FILE}"
  ${SUDO} install -m 0755 -d "${INSTALL_DIR}"
  ${SUDO} curl -fsSL "${RAW_BASE}/docker-compose.yml" -o "${COMPOSE_FILE}"
}

resolve_env_file() {
  if [[ -n "${ENV_FILE}" ]]; then
    echo "==> Using env file: ${ENV_FILE}"
    return
  fi

  ENV_FILE="$(dirname -- "${COMPOSE_FILE}")/.env"
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

disable_host_cloudflared() {
  if systemctl list-unit-files cloudflared.service >/dev/null 2>&1; then
    echo "==> Disabling host-level cloudflared service; Docker Compose will run cloudflared"
    ${SUDO} systemctl disable --now cloudflared >/dev/null 2>&1 || true
  fi
}

configure_cloudflared_env() {
  if [[ -z "${CLOUDFLARED_TOKEN:-}" ]] &&
    [[ -f "${ENV_FILE}" ]] &&
    ${SUDO} grep -q '^CLOUDFLARED_TOKEN=.' "${ENV_FILE}"; then
    echo "==> Using existing Cloudflare token from ${ENV_FILE}"
    return
  fi

  if [[ -z "${CLOUDFLARED_TOKEN:-}" && -r /dev/tty ]]; then
    echo "==> Paste Cloudflare Tunnel token, or press Enter to skip:" >/dev/tty
    IFS= read -r -s CLOUDFLARED_TOKEN </dev/tty || true
    echo >/dev/tty
  fi

  if [[ -n "${CLOUDFLARED_TOKEN:-}" ]]; then
    echo "==> Writing Cloudflare token to ${ENV_FILE}"
    ${SUDO} install -m 0755 -d "$(dirname -- "${ENV_FILE}")"
    printf 'CLOUDFLARED_TOKEN=%s\n' "${CLOUDFLARED_TOKEN}" | \
      ${SUDO} tee "${ENV_FILE}" >/dev/null
    ${SUDO} chmod 0600 "${ENV_FILE}"
  else
    echo "==> CLOUDFLARED_TOKEN not set; cloudflared container will not start"
    echo "    Re-run with: curl -fsSL ${RAW_BASE}/scripts/setup-apps.sh | bash"
  fi
}

has_cloudflared_token() {
  if [[ -n "${CLOUDFLARED_TOKEN:-}" ]]; then
    return 0
  fi

  [[ -f "${ENV_FILE}" ]] && ${SUDO} grep -q '^CLOUDFLARED_TOKEN=.' "${ENV_FILE}"
}

deploy_stack() {
  echo "==> Deploying Portainer"
  if has_cloudflared_token; then
    echo "==> Deploying cloudflared container"
    ${SUDO} docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" --profile cloudflare up -d
  else
    echo "==> Deploying without cloudflared; no Cloudflare token is configured"
    ${SUDO} docker compose -f "${COMPOSE_FILE}" up -d portainer
  fi
}

print_summary() {
  echo
  echo "Apps setup complete."
  echo
  echo "Next steps:"
  echo "1. Log out and back in before running docker without sudo."
  echo "2. In Cloudflare Tunnel, route Portainer to: https://portainer:9443"
  echo "3. If using Portainer via Cloudflare, enable 'No TLS Verify' for the origin."
  echo
  echo "Local Portainer URL, if you later have LAN access:"
  echo "https://<server-ip>:9443"
}

install_base_packages
resolve_compose_file
resolve_env_file
install_docker
disable_host_cloudflared
configure_cloudflared_env
deploy_stack
print_summary
