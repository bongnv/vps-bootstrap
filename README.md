# Home Server Infra

Bootstrap scripts for Ubuntu servers in the fleet.

- **Host**: runs Portainer and manages the fleet.
- **Agent**: runs the Portainer Agent and is managed from the host over Tailscale.

App stacks (Cloudflare Tunnel, Immich, etc.) live in the separate `vps-stacks` repository.

## Bootstrap the host

Generate a Tailscale auth key, then run this on the home server:

```bash
PORTAINER_ROLE=host \
TAILSCALE_AUTHKEY='tskey-auth-xxxxx' \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/bootstrap.sh)"
```

When it finishes, open Portainer at the URL printed by the script.

## Bootstrap an agent

Generate a Tailscale auth key, then run this on any managed node, including Oracle Cloud instances:

```bash
PORTAINER_ROLE=agent \
TAILSCALE_AUTHKEY='tskey-auth-xxxxx' \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/bootstrap.sh)"
```

The script auto-detects OCI and applies OCI-specific handling. If needed, force
or skip it with `ORACLE_CLOUD=true` or `ORACLE_CLOUD=false`.

No public SSH port is needed. Set `SSH_PORT=''` to skip the SSH firewall rule
and rely on Tailscale or the OCI Console Connection for access instead.

When it finishes, register the node in the Portainer host.

## Register an agent

In the Portainer host, go to **Environments → Add → Agent** and enter the
address printed by the bootstrap:

```text
<agent-host>.<tailnet>.ts.net:9001
```

This requires MagicDNS on the tailnet.

## Options

Prepend these environment variables when needed:

- `PORTAINER_ROLE=host|agent` — required; selects which role to bootstrap
- `TAILSCALE_AUTHKEY` — required; joins the tailnet without a prompt
- `TAILSCALE_HOSTNAME` — optional friendly name shown in Tailscale
- `SSH_PORT` — SSH port to allow in the firewall (default `22`); set to `''` to skip public SSH entirely
- `ORACLE_CLOUD=true|false` — force or skip OCI-specific handling for agents
