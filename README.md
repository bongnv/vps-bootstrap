# Home Server Infra

This public repository is the source of truth for the Ubuntu Server running on the MacBook Pro.

The bootstrap installs:

- Docker Engine and the Docker Compose plugin
- `cloudflared` from Cloudflare's apt repository as a host-level service
- Portainer CE via Docker Compose

## Bootstrap

On the Ubuntu server:

```bash
curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/bootstrap-ubuntu.sh | bash
```

The script will ask for the Cloudflare Tunnel token. Paste it at the prompt, or press Enter to skip tunnel service setup and only install Docker, `cloudflared`, and Portainer.

You can also pass the token inline, but this may save the token in shell history:

```bash
CLOUDFLARED_TOKEN='<paste-token-here>' bash -c "$(curl -fsSL https://raw.githubusercontent.com/bongnv/vps-infra/main/scripts/bootstrap-ubuntu.sh)"
```

The remote installer downloads `docker-compose.yml` to:

```text
/opt/vps-infra/docker-compose.yml
```

If you have a local checkout, you can still run:

```bash
./scripts/bootstrap-ubuntu.sh
```

## Cloudflare Routes

Recommended public hostnames for the tunnel:

```text
ssh.yourdomain.com        -> ssh://localhost:22
portainer.yourdomain.com  -> https://localhost:9443
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
