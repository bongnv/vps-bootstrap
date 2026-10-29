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
- `ENABLE_TAILSCALE_SSH=true|false` — enable Tailscale SSH (default `true`); lets you SSH over the tailnet without keys or open firewall ports
- `ORACLE_CLOUD=true|false` — force or skip OCI-specific handling for agents

## Set up a Tailscale exit node

Use a supported Ubuntu Server release with systemd, IPv6 enabled in the kernel,
and root or sudo access. A public IPv6 address is not required for IPv4 use.
This is a standalone setup. It does not install Docker or Portainer, and it does
not reset host or cloud firewall rules.

From a checkout on the server:

```bash
bash scripts/setup-tailscale-exit-node.sh
```

The script reuses `scripts/install-tailscale.sh` to install Tailscale and SSH,
enable their services at boot, and join the tailnet. When prompted, paste an
auth key or press Enter and open the displayed login URL in a browser.
Keep your existing SSH session open until you have verified client connectivity.

Package installation is noninteractive. Existing SSH and other package
configuration files are kept, and needrestart reports pending service restarts
without prompting or performing them. Package maintainer scripts may still
restart their own services. Review the output and schedule any required restarts
or reboot afterward. For a fully unattended run, use root or configure sudo
access without a password, and provide a Tailscale auth key.

For an unattended run, provide `TAILSCALE_AUTHKEY`. To avoid putting it in shell
history, read it into the environment first:

```bash
read -rsp 'Tailscale auth key: ' TAILSCALE_AUTHKEY; echo
export TAILSCALE_AUTHKEY
TAILSCALE_HOSTNAME=ubuntu-exit bash scripts/setup-tailscale-exit-node.sh
unset TAILSCALE_AUTHKEY
```

To run without cloning, download the wrapper into a private directory first.
This requires the scripts to be published on the chosen branch:

```bash
workdir="$(mktemp -d)"
curl -fsSL https://raw.githubusercontent.com/bongnv/vps-bootstrap/main/scripts/setup-tailscale-exit-node.sh \
  -o "${workdir}/setup-tailscale-exit-node.sh"
bash "${workdir}/setup-tailscale-exit-node.sh"
```

The wrapper requires `sysctl`, provided by Ubuntu's standard `procps` package.
When there is no adjacent `install-tailscale.sh`, it also requires an existing
`curl` command to download the installer from the same repository. The wrapper
does not install packages itself. Set `VPS_INFRA_RAW_BASE` to a trusted raw
repository URL to fetch the installer from a different revision. Use matching
wrapper and installer revisions. A local adjacent installer takes precedence.

Exit node options:

* `TAILSCALE_AUTHKEY`: optional for interactive setup; required for unattended
  login when the machine is not already connected.
* `TAILSCALE_HOSTNAME`: optional name. An existing name is preserved if omitted.
* `ENABLE_TAILSCALE_SSH=true|false`: optional. For a new connection the default is
  `false`; on an existing connection the current setting is preserved if omitted.
  Tailscale SSH also requires tailnet policy authorization.

The wrapper verifies the connection, writes
`/etc/sysctl.d/99-tailscale-exit-node.conf`, and enables IPv4 and IPv6 forwarding.
It preserves IPv6 router advertisement reception on interfaces where it is
enabled, so enabling forwarding does not remove an address or route learned that
way. It then advertises the exit node and enables Tailscale netfilter management
and source NAT. Other existing Tailscale preferences are not reset. If login
requires restoring old nondefault flags, the installer fails rather than resetting
them. Resolve that login with `tailscale up` and rerun the wrapper.

### Approve and verify

1. Open <https://login.tailscale.com/admin/machines>, find the server, open
   **Edit route settings**, and approve **Use as exit node**. If machine approval
   is enabled, approve the machine before rerunning setup. Tailnet policy must
   allow the intended clients to use internet routes.
2. Select the server in a client's Tailscale **Exit Node** menu, or on Linux run
   `sudo tailscale set --exit-node=<server-tailscale-ip>`.
3. Run `curl -4 https://ifconfig.me` on the client and server. Their public IPv4
   addresses should match. If the server has working upstream IPv6, also compare
   `curl -6 https://ifconfig.me`. These checks contact a public IP lookup service.
4. Reboot the server and repeat the client check to verify persistent setup.

Local checks on the server:

```bash
systemctl is-enabled tailscaled
systemctl is-active tailscaled
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
tailscale status
```

A successful script run confirms local configuration, not working client egress.
If traffic fails, inspect host and cloud firewall forwarding restrictions,
Tailscale health warnings, and tailnet policy. This script does not clear OCI
firewall rules or change cloud security lists. Do not disable the firewall or open
all public ports to troubleshoot.

### Disable exit node use

On each client, run `sudo tailscale set --exit-node=` or select **None** in its
Exit Node menu. On the server, run
`sudo tailscale set --advertise-exit-node=false` and remove its exit node approval
in the admin console. This leaves forwarding enabled. To restore the previous
host networking configuration, remove the managed sysctl file and restore the
previous forwarding and router advertisement values. Do not disable forwarding
if another service needs it.

## Script validation

Check shell syntax with:

```bash
for script in scripts/*.sh; do bash -n "$script" || exit; done
```

Syntax checks do not prove actual VPN routing. Use the client checks above on
Ubuntu for live validation.
