#!/usr/bin/env bash
set -euo pipefail

# Deploy a Portainer server (the central control plane, e.g. the home server)
# and front it with Tailscale Serve so it is reachable over HTTPS with a trusted
# certificate. Runs setup-common.sh first if Docker is not yet installed.

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script must be run on the Ubuntu server."
  exit 1
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
fi

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
fi

INSTALL_DIR="${INSTALL_DIR:-/opt/vps-infra}"
RAW_BASE="${VPS_INFRA_RAW_BASE:-https://raw.githubusercontent.com/bongnv/vps-infra/main}"
COMPOSE_FILE="${COMPOSE_FILE:-}"

# Front Portainer with Tailscale Serve (HTTPS on 9443). Set to false to skip.
ENABLE_PORTAINER_SERVE="${ENABLE_PORTAINER_SERVE:-true}"

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

ensure_common() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi
  echo "==> Docker not found; running setup-common.sh first"
  run_local_or_remote "setup-common.sh"
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

deploy_stack() {
  echo "==> Deploying Portainer"
  ${SUDO} docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans portainer
}

serve_portainer() {
  # Front Portainer's HTTPS UI/API with Tailscale Serve so it is reachable at
  # https://<host>.<tailnet>.ts.net:9443 with a trusted certificate. Requires
  # HTTPS enabled once per tailnet in the admin console (MagicDNS).
  if [[ "${ENABLE_PORTAINER_SERVE}" != "true" ]]; then
    return
  fi

  if ! ${SUDO} tailscale status --json 2>/dev/null | grep -q '"BackendState":"Running"'; then
    echo "==> Tailscale is not connected; skipping Portainer serve setup"
    echo "    Once connected, run: sudo tailscale serve --bg --https=9443 https+insecure://127.0.0.1:9443"
    return
  fi

  echo "==> Exposing Portainer over Tailscale Serve (https :9443)"
  ${SUDO} tailscale serve --bg --https=9443 "https+insecure://127.0.0.1:9443"
}

print_summary() {
  local serve_host
  serve_host="$(${SUDO} tailscale status --json 2>/dev/null | grep -o '"DNSName":"[^"]*"' | head -n 1 | cut -d'"' -f4 | sed 's/\.$//' || true)"

  echo
  echo "Portainer host setup complete."
  echo
  echo "Next steps:"
  echo "1. Log out and back in before running docker without sudo."
  echo "2. Reach Portainer over Tailscale (trusted HTTPS):"
  if [[ -n "${serve_host}" ]]; then
    echo "   https://${serve_host}:9443"
  else
    echo "   https://<host>.<tailnet>.ts.net:9443"
  fi
  echo "3. Add remote nodes via Environments -> Add -> Agent (host:9001)."
}

ensure_common
resolve_compose_file
deploy_stack
serve_portainer
print_summary
