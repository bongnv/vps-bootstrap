# Home Server Infra

This public repository is the source of truth for the Ubuntu Server running on the MacBook Pro.

The setup is split into two stages:

- Stage 1: install OpenSSH and Tailscale from the MacBook console
- Stage 2: SSH in over Tailscale, then install Docker, Portainer, and the Dockerized Cloudflare Tunnel

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
- `cloudflared` via Docker Compose for Portainer and web app ingress

It will ask for a Cloudflare Tunnel token. Paste one to start the `cloudflared` container, or press Enter to skip Cloudflare ingress for now.

You can also pass the token inline, but this may save it in shell history:

```bash
CLOUDFLARED_TOKEN='<paste-cloudflare-token>' \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/setup-apps.sh)"
```

The remote installer downloads `docker-compose.yml` to:

```text
/opt/vps-infra/docker-compose.yml
```

If you provide a Cloudflare token, the installer writes it to:

```text
/opt/vps-infra/.env
```

## Compatibility Bootstrap

The old all-in-one bootstrap still exists as a wrapper:

```bash
curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/bootstrap-ubuntu.sh | bash
```

Prefer the two-stage flow above so the heavier app setup happens from SSH.

## Cloudflare Routes

Use Cloudflare Tunnel only for Portainer and deployed web apps. Because `cloudflared` runs in Docker, route to Docker service names on the shared `tunnel` network, not `localhost`.

Recommended public hostnames for the tunnel:

```text
portainer.yourdomain.com  -> https://portainer:9443
photos.yourdomain.com     -> http://<immich-service-name>:2283
```

For Portainer, enable Cloudflare's origin setting equivalent to **No TLS Verify**, because Portainer uses a self-signed local certificate.

Keep Portainer behind Cloudflare Access with MFA.

## Portainer

Portainer CE is defined in `docker-compose.yml`.

After bootstrap, the local URL is:

```text
https://<server-ip>:9443
```

If you cannot reach the server over LAN, use the Cloudflare Tunnel route instead.

## App Stacks

Future web app stacks should join the external Docker network named `tunnel` if Cloudflare needs to reach them.
