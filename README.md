# Home Server Infra

This public repository is the source of truth for the Ubuntu Server running on the MacBook Pro.

The setup is split into two stages:

- Stage 1: install OpenSSH and Tailscale from the MacBook console
- Stage 2: SSH in over Tailscale, then install Docker and Portainer

## Stage 1: Tailscale

Run this on the Ubuntu server console:

```bash
curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/install-tailscale.sh | bash
```

The script will ask for a Tailscale auth key. Paste one to join the server unattended, or press Enter to use the browser login URL shown by `tailscale up`.

You can also pass the auth key inline, but this may save it in shell history:

```bash
TAILSCALE_AUTHKEY='<paste-tailscale-auth-key>' \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/install-tailscale.sh)"
```

After it joins your tailnet, SSH from another device signed in to Tailscale:

```bash
ssh <ubuntu-user>@<tailscale-ip-or-hostname>
```

By default this uses normal Ubuntu OpenSSH over the Tailscale private network. If you specifically want the Tailscale SSH feature, enable it explicitly and make sure your Tailscale ACLs allow it:

```bash
ENABLE_TAILSCALE_SSH=true \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/install-tailscale.sh)"
```

## Stage 2: Apps

Run this from the SSH session:

```bash
curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/setup-apps.sh | bash
```

The script installs:

- Docker Engine and the Docker Compose plugin
- Portainer CE via Docker Compose

The remote installer downloads `docker-compose.yml` to:

```text
/opt/vps-infra/docker-compose.yml
```

## Compatibility Bootstrap

The old all-in-one bootstrap still exists as a wrapper:

```bash
curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/bootstrap-ubuntu.sh | bash
```

Prefer the two-stage flow above so the heavier app setup happens from SSH.

## Cloudflare and App Stacks

Cloudflare Tunnel, Immich, and other application stacks are managed from the separate `vps-stacks` repository.

Keep Portainer private and access it over Tailscale from trusted clients or GitHub Actions:

```text
https://<tailscale-ip-or-hostname>:9443
```

## Portainer

Portainer CE is defined in `docker-compose.yml`.

After bootstrap, the local URL is:

```text
https://<server-ip>:9443
```

If you cannot reach the server over LAN, use the Tailscale address instead.

## App Stacks

Future web app stacks should live in the separate `vps-stacks` repository.
