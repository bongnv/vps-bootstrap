"""Exercise shell behavior with host operations replaced by local test doubles."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/setup-tailscale-exit-node.sh"
INSTALLER = ROOT / "scripts/install-tailscale.sh"

MOCKS = r'''
SUDO=""
apt-get() { echo "apt-get $*" >>"$LOG"; }
systemctl() { echo "systemctl $*" >>"$LOG"; }
install() { echo "install $*" >>"$LOG"; }
tee() {
  if [[ "$1" == "${SYSCTL_FILE:-}" ]]; then
    builtin command tee "$1"
  else
    cat >/dev/null
  fi
}
curl() {
  echo "curl $*" >>"$LOG"
  [[ "${DOWNLOAD_FAIL:-false}" != true ]] || return 22
  if [[ "${3:-}" == -o ]]; then
    cp "$TEST_INSTALLER" "$4"
  else
    echo repository-data
  fi
}
sysctl() {
  echo "sysctl $*" >>"$LOG"
  if [[ "$1" == -p ]]; then
    [[ "${SYSCTL_FAIL:-false}" != true ]] || return 1
  elif [[ "$2" == net.ipv6.conf.all.disable_ipv6 ]]; then
    echo "${IPV6_DISABLED:-0}"
  else
    echo "${FORWARDING:-1}"
  fi
}
tailscale() {
  echo "tailscale $*" >>"$LOG"
  case "$1" in
    status)
      if [[ -f "$WORK/connected" ]]; then
        echo '{"BackendState": "Running"}'
      else
        printf '{"BackendState": "%s"}\n' "${STATE:-NeedsLogin}"
        return "${STATUS_RC:-0}"
      fi
      ;;
    up)
      [[ "${LOGIN_FAIL:-false}" != true ]] || return 1
      for arg in "$@"; do
        if [[ "$arg" == --auth-key=file:* ]]; then
          keyfile="${arg#--auth-key=file:}"
          [[ "$(cat "$keyfile")" == "$EXPECTED_KEY" ]] || return 1
          echo "$keyfile" >"$WORK/keypath"
          stat -f '%Lp' "$keyfile" 2>/dev/null >"$WORK/keymode" || \
            stat -c '%a' "$keyfile" >"$WORK/keymode"
        fi
      done
      touch "$WORK/connected"
      ;;
    set) [[ "${SET_FAIL:-false}" != true ]] || return 1 ;;
    ip) echo 100.64.0.10 ;;
  esac
}
command() {
  if [[ "$*" == '-v tailscale' && "${FRESH:-false}" == true ]]; then
    return 1
  fi
  builtin command "$@"
}
export -f apt-get systemctl install tee curl sysctl tailscale command
ipv6_ra_settings() { echo 'net/ipv6/conf/eth0/accept_ra = 2'; }
preflight() { :; }
'''


class ExitNodeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.script = self.work / SCRIPT.name
        shutil.copyfile(SCRIPT, self.script)
        self.installer = self.work / INSTALLER.name
        self.installer.write_text(
            f"source {shlex.quote(str(INSTALLER))}\n"
            'prepare_host() { SUDO=""; TARGET_USER=test; '
            'VERSION_CODENAME=noble; RAW_BASE=https://example.test; }\n'
            'has_terminal() { return "${NO_TTY:-1}"; }\n'
            'prompt_authkey() { :; }\n'
            'main\n'
        )
        self.log = self.work / "commands"
        self.log.touch()
        self.env = {
            **os.environ,
            "WORK": str(self.work),
            "LOG": str(self.log),
            "TEST_INSTALLER": str(self.installer),
            "STATE": "NeedsLogin",
            "TAILSCALE_AUTHKEY": "test-secret",
            "EXPECTED_KEY": "test-secret",
            "ENABLE_TAILSCALE_SSH": "",
            "TAILSCALE_HOSTNAME": "",
            "TAILSCALE_EXTRA_ARGS": "",
            "FRESH": "false",
        }

    def run_shell(self, body="main", **env):
        code = (
            f"source {shlex.quote(str(self.script))}\n"
            + MOCKS
            + f'\nSYSCTL_FILE={shlex.quote(str(self.work / "forwarding.conf"))}\n'
            + body
        )
        return subprocess.run(
            ["bash", "-c", code], env={**self.env, **env},
            text=True, capture_output=True, timeout=10,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fresh_install_reuses_installer_and_advertises(self):
        result = self.run_shell(FRESH="true")
        self.assert_success(result)
        log = self.log.read_text()
        self.assertIn("apt-get install -y tailscale", log)
        self.assertIn("systemctl enable --now tailscaled", log)
        self.assertIn("tailscale up", log)
        self.assertIn("--auth-key=file:", log)
        self.assertNotIn("test-secret", log + result.stdout + result.stderr)
        keypath = Path((self.work / "keypath").read_text().strip())
        self.assertFalse(keypath.exists())
        self.assertEqual((self.work / "keymode").read_text().strip(), "600")
        self.assertIn("--advertise-exit-node --netfilter-mode=on --snat-subnet-routes=true", log)
        self.assertNotIn("ufw", log)
        self.assertNotIn("iptables", log)
        self.assertNotIn("docker", log)
        config = (self.work / "forwarding.conf").read_text()
        self.assertIn("net.ipv4.ip_forward = 1", config)
        self.assertIn("net.ipv6.conf.all.forwarding = 1", config)
        self.assertLess(config.index("accept_ra"), config.index("forwarding"))
        self.assertIn("--exit-node=100.64.0.10", result.stdout)
        self.assertIn("Admin approval and client testing remain", result.stdout)

    def test_rerun_preserves_connection_and_other_preferences(self):
        self.assert_success(self.run_shell(STATE="Running"))
        first = (self.work / "forwarding.conf").read_text()
        self.assert_success(self.run_shell(STATE="Running"))
        self.assertEqual(first, (self.work / "forwarding.conf").read_text())
        log = self.log.read_text()
        self.assertNotIn("tailscale up", log)
        self.assertNotIn("--reset", log)
        self.assertNotIn("--ssh", log)
        self.assertNotIn("--hostname", log)
        self.assertNotIn("apt-get install -y tailscale", log)

    def test_explicit_hostname_and_ssh(self):
        self.assert_success(self.run_shell(
            STATE="Running", TAILSCALE_HOSTNAME="exit-london", ENABLE_TAILSCALE_SSH="true",
        ))
        log = self.log.read_text()
        self.assertIn("--hostname=exit-london --ssh=true", log)

    def test_login_failure_stops_before_forwarding(self):
        result = self.run_shell(LOGIN_FAIL="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("sysctl -p", self.log.read_text())
        self.assertNotIn("tailscale set", self.log.read_text())

    def test_missing_login_stops_before_forwarding(self):
        result = self.run_shell(TAILSCALE_AUTHKEY="", NO_TTY="1", STATUS_RC="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Complete login or machine approval", result.stderr)
        self.assertFalse((self.work / "forwarding.conf").exists())

    def test_browser_login(self):
        self.assert_success(self.run_shell(TAILSCALE_AUTHKEY="", NO_TTY="0"))
        self.assertIn("tailscale up", self.log.read_text())
        self.assertNotIn("--auth-key", self.log.read_text())

    def test_forwarding_failures_do_not_advertise(self):
        for env in ({"SYSCTL_FAIL": "true"}, {"IPV6_DISABLED": "1"}, {"FORWARDING": "0"}):
            with self.subTest(env=env):
                self.log.write_text("")
                result = self.run_shell(STATE="Running", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("tailscale set", self.log.read_text())

    def test_advertise_failure_does_not_report_completion(self):
        result = self.run_shell(STATE="Running", SET_FAIL="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Local exit node configuration complete", result.stdout)

    def test_downloaded_wrapper_fetches_shared_installer(self):
        self.installer.rename(self.work / "download-source.sh")
        result = self.run_shell(
            TEST_INSTALLER=str(self.work / "download-source.sh"),
            VPS_INFRA_RAW_BASE="https://example.test/revision", STATE="Running",
        )
        self.assert_success(result)
        self.assertIn("https://example.test/revision/scripts/install-tailscale.sh", self.log.read_text())

    def test_process_substitution_uses_default_repository(self):
        entrypoint = self.work / "entrypoint.sh"
        content = SCRIPT.read_text().replace("  preflight\n", "  :\n")
        content = content.replace(
            'SYSCTL_FILE="/etc/sysctl.d/99-tailscale-exit-node.conf"',
            'SYSCTL_FILE="$WORK/forwarding.conf"',
        )
        entrypoint.write_text(content)
        result = self.run_shell(
            'bash <(cat "$ENTRYPOINT")', ENTRYPOINT=str(entrypoint), STATE="Running",
        )
        self.assert_success(result)
        self.assertIn(
            "https://raw.githubusercontent.com/bongnv/vps-bootstrap/main/scripts/install-tailscale.sh",
            self.log.read_text(),
        )

    def test_download_failure_does_not_execute_installer(self):
        self.installer.unlink()
        result = self.run_shell(DOWNLOAD_FAIL="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("systemctl", self.log.read_text())
        self.assertFalse((self.work / "forwarding.conf").exists())

    def test_source_has_no_host_side_effects(self):
        code = f'source {shlex.quote(str(INSTALLER))}; source {shlex.quote(str(SCRIPT))}'
        result = subprocess.run(["bash", "-c", code], text=True, capture_output=True, timeout=5)
        self.assert_success(result)
        self.assertEqual(result.stdout, "")

    def test_rejects_non_linux(self):
        result = self.run_shell('unset -f preflight; source "$ORIGINAL"; uname() { echo Darwin; }; preflight', ORIGINAL=str(SCRIPT))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Run this script on Ubuntu Server", result.stderr)
        self.assertEqual(self.log.read_text(), "")


if __name__ == "__main__":
    unittest.main()
