# Home Server Infra

This public repository is the source of truth for the Ubuntu Server running on the MacBook Pro.

The bootstrap installs:

- Docker Engine and the Docker Compose plugin
- OpenSSH server for local fallback access
- Tailscale from Tailscale's apt repository for SSH/admin access over the tailnet
- `cloudflared` from Cloudflare's apt repository as a host-level service
- Portainer CE via Docker Compose

## Bootstrap

On the Ubuntu server:

```bash
curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/bootstrap-ubuntu.sh | bash
```

The script will ask for:

- A Tailscale auth key. Paste one to join the server unattended, or press Enter to use the browser login URL shown by `tailscale up`.
- A Cloudflare Tunnel token. Paste one to connect the tunnel for Portainer and web apps, or press Enter to skip tunnel service setup.

You can also pass tokens inline, but this may save them in shell history:

```bash
TAILSCALE_AUTHKEY='<paste-tailscale-auth-key>' \
CLOUDFLARED_TOKEN='<paste-cloudflare-token>' \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/bootstrap-ubuntu.sh)"
```

The remote installer downloads `docker-compose.yml` to:

```text
/opt/vps-infra/docker-compose.yml
```

If you have a local checkout, you can still run:

```bash
./scripts/bootstrap-ubuntu.sh
```

## SSH

SSH/admin access should go through Tailscale, not Cloudflare.

By default this uses normal Ubuntu OpenSSH over the Tailscale private network. From another device in your tailnet:

```bash
ssh <ubuntu-user>@<tailscale-hostname>
```

If you specifically want the Tailscale SSH feature, enable it explicitly and make sure your Tailscale ACLs allow it:

```bash
ENABLE_TAILSCALE_SSH=true ./scripts/bootstrap-ubuntu.sh
```

## Cloudflare Routes

Use Cloudflare Tunnel only for Portainer and deployed web apps.

Recommended public hostnames for the tunnel:

```text
portainer.yourdomain.com  -> https://localhost:9443
photos.yourdomain.com     -> http://localhost:2283
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
