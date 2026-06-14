#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="${VPS_INFRA_RAW_BASE:-https://raw.githubusercontent.com/bongnv/vps-infra/main}"

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

echo "This compatibility wrapper runs both setup stages."
echo "For the normal flow, run install-tailscale.sh first, then setup-apps.sh over SSH."
echo

run_local_or_remote "install-tailscale.sh"
run_local_or_remote "setup-apps.sh"
