#!/usr/bin/env bash
set -euo pipefail

# Deploy a Portainer Agent on a node managed by a central Portainer server (e.g.
# an OCI box managed by the home server over Tailscale). The Agent listens on
# 9001 and is only reachable over the tailscale0 interface thanks to the UFW
# baseline. It handles its own TLS with the Portainer server, so it does not use
# Tailscale Serve. Runs setup-common.sh first if Docker is not yet installed.

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
    local_compose="${repo_dir}/docker-compose.agent.yml"

    if [[ -f "${local_compose}" ]]; then
      COMPOSE_FILE="${local_compose}"
      echo "==> Using local compose file: ${COMPOSE_FILE}"
      return
    fi
  fi

  COMPOSE_FILE="${INSTALL_DIR}/docker-compose.agent.yml"
  echo "==> Downloading compose file to ${COMPOSE_FILE}"
  ${SUDO} install -m 0755 -d "${INSTALL_DIR}"
  ${SUDO} curl -fsSL "${RAW_BASE}/docker-compose.agent.yml" -o "${COMPOSE_FILE}"
}

deploy_stack() {
  echo "==> Deploying Portainer Agent"
  ${SUDO} docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans agent
}

print_summary() {
  local agent_host
  agent_host="$(${SUDO} tailscale status --json 2>/dev/null | grep -o '"DNSName":"[^"]*"' | head -n 1 | cut -d'"' -f4 | sed 's/\.$//' || true)"

  echo
  echo "Portainer Agent setup complete."
  echo
  echo "Next steps:"
  echo "1. Log out and back in before running docker without sudo."
  echo "2. This node runs the Portainer Agent on port 9001 (tailscale0 only)."
  echo "3. Add it in your central Portainer: Environments -> Add -> Agent, using:"
  if [[ -n "${agent_host}" ]]; then
    echo "   ${agent_host}:9001"
  else
    echo "   <this-host>.<tailnet>.ts.net:9001"
  fi
}

ensure_common
resolve_compose_file
deploy_stack
print_summary
