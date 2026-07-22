#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="${VPS_INFRA_RAW_BASE:-https://raw.githubusercontent.com/bongnv/vps-infra/main}"
PORTAINER_ROLE="${PORTAINER_ROLE:-}"

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
fi

usage() {
  cat >&2 <<EOF
Usage:
  PORTAINER_ROLE=host  TAILSCALE_AUTHKEY='tskey-auth-xxxxx' bash -c "\$(curl -fsSL ${RAW_BASE}/scripts/bootstrap.sh)"
  PORTAINER_ROLE=agent TAILSCALE_AUTHKEY='tskey-auth-xxxxx' bash -c "\$(curl -fsSL ${RAW_BASE}/scripts/bootstrap.sh)"

PORTAINER_ROLE must be one of: host, agent
EOF
}

require_inputs() {
  if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
    echo "TAILSCALE_AUTHKEY is required for bootstrap." >&2
    echo "Generate one in Tailscale admin -> Settings -> Keys." >&2
    usage
    exit 1
  fi

  case "${PORTAINER_ROLE}" in
    host|agent) ;;
    *)
      echo "PORTAINER_ROLE is required and must be 'host' or 'agent'." >&2
      usage
      exit 1
      ;;
  esac

  export TAILSCALE_AUTHKEY
}

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

is_oracle_cloud() {
  if [[ -n "${ORACLE_CLOUD:-}" ]]; then
    [[ "${ORACLE_CLOUD}" == "true" ]]
    return
  fi

  local marker
  marker="$(cat /sys/class/dmi/id/product_name /sys/class/dmi/id/chassis_asset_tag 2>/dev/null || true)"
  grep -qiE 'oracle|oci' <<<"${marker}"
}

clear_oracle_iptables() {
  echo "==> Clearing Oracle's default instance-level iptables rules"

  ${SUDO} apt-get update
  ${SUDO} apt-get install -y iptables

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

  if command -v netfilter-persistent >/dev/null 2>&1; then
    ${SUDO} netfilter-persistent save || true
  fi
}

print_summary() {
  echo
  if [[ "${PORTAINER_ROLE}" == "host" ]]; then
    echo "Portainer host bootstrap complete."
    echo "Open Portainer at the URL printed above."
  else
    echo "Portainer agent bootstrap complete."
    echo "Register this node in the Portainer host: Environments -> Add -> Agent."
  fi
}

require_inputs

echo "This bootstrap sets up a Portainer ${PORTAINER_ROLE}."
echo

if [[ "${PORTAINER_ROLE}" == "agent" ]] && is_oracle_cloud; then
  clear_oracle_iptables
fi

run_local_or_remote "install-tailscale.sh"

if [[ "${PORTAINER_ROLE}" == "host" ]]; then
  run_local_or_remote "setup-portainer-host.sh"
else
  run_local_or_remote "setup-portainer-agent.sh"
fi

print_summary
