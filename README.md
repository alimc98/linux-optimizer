# Linux Optimizer

A bash script that automates the well-known, safe optimizations for a Linux **server** (VPS / VDS / dedicated / bare metal).

**Ubuntu 22.04+ · Debian 12+ · Fedora 42+ · CentOS Stream / AlmaLinux / Rocky Linux / CloudLinux 8+**

---

## Table of contents

- [What it does](#what-it-does)
- [Quick start](#quick-start)
- [Command line](#command-line)
- [What changed in v2.0](#what-changed-in-v20)
- [Notes & warnings](#notes--warnings)
- [Where everything gets written](#where-everything-gets-written)
- [Undoing it](#undoing-it)
- [Testing](#testing)
- [Contributing](#contributing)
- [License](#license)

---

## What it does

Every step is **idempotent** — running the script ten times is identical to running it once.

| Step | Description |
|------|-------------|
| `update`   | Update, upgrade, dist-upgrade, autoremove, clean |
| `ads`      | Disable Ubuntu's terminal adverts (`motd-news`, Ubuntu Pro `apt-news`) |
| `packages` | Install useful tooling: `htop`, `jq`, `vim`, `nano`, `screen`, `socat`, `build-essential`/`gcc`, `git`, `python3`, `ufw`, `net-tools`, … |
| `swap`     | Create & enable a swapfile (auto-sized from RAM, `--swap-size` to force) |
| `sysctl`   | Network / TCP / BBR / VM tuning via a `/etc/sysctl.d/` drop-in |
| `ssh`      | SSH tuning via an `sshd_config.d/` drop-in (never rewrites your `sshd_config`) |
| `limits`   | `nofile` / `nproc` / `memlock` via `limits.d/` (pam_limits — works for services too) |
| `hosts`    | Make sure `hostname` resolves in `/etc/hosts` |
| `dns`      | Fallback DNS via a `systemd-resolved` drop-in (never clobbers a managed `resolv.conf`) |
| `timezone` | Set the timezone from the server's public IP (3 sources, majority vote) |
| `firewall` | UFW: allow `SSH`, `80`, `443` + rate-limit SSH; keeps a pre-existing ruleset unless you say otherwise |
| `kernel`   | **Debian/Ubuntu only** — install the XanMod kernel (see warnings below) |

---

## Quick start

```bash
sudo -i
wget -qO- https://raw.githubusercontent.com/alimc98/linux-optimizer/main/linux-optimizer.sh | bash
```

The interactive menu appears. Pick **1** to apply everything.

Prefer to read before running (recommended on a production box)?

```bash
sudo -i
git clone https://github.com/alimc98/linux-optimizer && cd linux-optimizer
bash linux-optimizer.sh --list      # see exactly what it would do
bash linux-optimizer.sh             # menu
```

Everything is logged to `/var/log/linux-optimizer.log`.

---

## Command line

```
--all                 Every safe step (no kernel)
--kernel              Also install the XanMod kernel (Debian/Ubuntu only)
--step NAME           Run one step. Repeatable.
--skip NAME           Skip a step --all would run. Repeatable.
--list                List step names
--yes                 Never ask
--no-reboot           Never reboot
--reboot              Reboot at the end without asking
--swap-size SIZE      2G / 1G / 512M (default: auto by RAM)
--dns "A B"           Fallback DNS servers (default: "1.1.1.1 8.8.8.8")
--ssh-port PORT       Force the SSH port instead of parsing sshd_config
--log FILE            Log file (default /var/log/linux-optimizer.log)
--non-interactive     No prompts; implies --yes --no-reboot
```

Examples:

```bash
# Provisioning script / cloud-init: everything, no questions, no reboot
bash linux-optimizer.sh --all --non-interactive

# Just networking and SSH, keep everything else as-is
bash linux-optimizer.sh --step sysctl --step ssh --yes

# Everything except the firewall (you manage nftables yourself)
bash linux-optimizer.sh --all --skip firewall
```

---

## What changed in v2.0

The previous version was four near-identical 900–1000 line scripts. v2.0 is a shared `lib/` with thin per-distro entry points, and fixes a number of things that were actively harmful:

| Was | Now |
|-----|-----|
| `tee -a` appended SSH directives to `sshd_config` on **every run**, and `ulimit` lines to `/etc/profile` | Proper drop-in files in `sshd_config.d/` and `limits.d/`. Re-running replaces them. |
| `sed` rewrote `/etc/sysctl.conf`, deleting keys it didn't recognise | Own `/etc/sysctl.d/99-linux-optimizer.conf`. Legacy pollution is cleaned up once, with a backup. |
| `vm.overcommit_memory = 2` | `0`. Strict overcommit made PHP/Redis/MariaDB hosts fail `fork()` **while memory was still free**. |
| `fs.file-max = 67108864` | `2097152`. Anything above `INT_MAX` is silently clamped by the kernel anyway. |
| `net.ipv4.tcp_mem = ... 33554432` | Explicit page-based limits. `tcp_mem` is measured in **pages**, and the old number was understood as bytes by almost everyone. |
| `kernel.panic = 1` | `10`. One second is too fast to read the oops on a remote machine. |
| `Ciphers aes256-ctr,chacha20-poly1305@openssh.com` | A complete, modern suite set including `*-gcm` (fastest on AES-NI). |
| XanMod repo line `http://deb.xanmod.org releases main` | `http://deb.xanmod.org $(codename) main` — the `releases` suite **404s today**, so kernel installs have been broken since the repo layout changed. Also probes `x64v2`/`x64v3`/LTS instead of assuming `x64v$level` exists. |
| UFW enabled with a hardcoded ruleset | Detects an existing ruleset and asks before replacing it. |
| No firewall rollback | SSH port is opened *before* `ufw enable`, and failures are loud. |
| `resolv.conf` rewritten directly | `systemd-resolved` drop-in when resolved is running; leaves the stub symlink alone. |
| No tests, no CI | `tests/run-tests.sh` (offline, 110+ assertions) + GitHub Actions. |

---

## Notes & warnings

1. **Servers only.** This is for VPS / VDS / dedicated / bare-metal. Don't run it on a desktop.
2. **The kernel options (1 / 2 / `--kernel`) can break GPU drivers.** XanMod + NVIDIA/VirtualBox/VMware DKMS modules is a known source of pain, and XanMod builds with its own LLVM toolchain.
3. **Some VMs do not survive a kernel swap.** On `kvm`/`qemu`/`xen`/`vmware`/`microsoft` the script will ask before touching the kernel. Test first, and keep provider console/recovery access.
4. **This script will not lock you out of SSH.** It validates with `sshd -t` *after* writing its drop-in and rolls the change back if the config is invalid, so a bad edit never becomes a reboot you can't get back into.
5. **Read `/etc/sysctl.d/99-linux-optimizer.conf` before applying it to an unusual host.** Buffer sizes sized for a big box are wasteful on a 512MB VPS; the file explains each value.
6. UFW opening only 22/80/443 means **you must open your own panel/VPN ports manually** — the script tells you the exact command.

---

## Where everything gets written

| File | Purpose |
|------|---------|
| `/etc/sysctl.d/99-linux-optimizer.conf` | Network / kernel tuning |
| `/etc/security/limits.d/99-linux-optimizer.conf` | ulimits for services too |
| `/etc/ssh/sshd_config.d/99-linux-optimizer.conf` | SSH tuning (or a marked block in `sshd_config` on old OpenSSH) |
| `/etc/systemd/resolved.conf.d/99-linux-optimizer.conf` | Fallback DNS |
| `/etc/apt/sources.list.d/xanmod-release.list` | XanMod repo (only with `--kernel`) |
| `/var/log/linux-optimizer.log` | Full log of every run |
| `/root/linux-optimizer-backups/` | Timestamped backups |
| `*.pre-lo.bak` next to each edited file | First-ever copy of any file we had to edit in place |

Drop-ins named `99-…` are beaten by any file that sorts after them, so **your own overrides go in `zz-local.conf`** and survive future runs untouched.

---

## Undoing it

```bash
rm -f /etc/sysctl.d/99-linux-optimizer.conf              && sysctl --system
rm -f /etc/security/limits.d/99-linux-optimizer.conf
rm -f /etc/ssh/sshd_config.d/99-linux-optimizer.conf     && systemctl restart sshd
rm -f /etc/systemd/resolved.conf.d/99-linux-optimizer.conf && systemctl restart systemd-resolved
```

To also remove the swapfile: `swapoff /swapfile && rm -f /swapfile` and delete its `/etc/fstab` line.

Reverting a kernel is a GRUB action: boot the previous entry, then `apt purge 'linux-*xanmod*'`.

---

## Testing

```bash
bash tests/run-tests.sh
```

Runs anywhere (no root, no network, no apt/dnf): every destination path is redirected into a throwaway sandbox, so it verifies detection, sizing, drop-in content, rollback and idempotency. `shellcheck` clean is enforced in CI along with `bash -n` on every file.

---

## Structure

```
linux-optimizer.sh          # entry point (works standalone: fetches lib/ + files/)
lib/
  common.sh                 # messages, root check, retry, backups, sizing helpers
  detect.sh                 # /etc/os-release parsing, family + support policy
  optimize.sh               # every module (update, xanmod, swap, sysctl, ssh, …)
  cli.sh                    # step table, argument parsing, interactive menu
  loader.sh                 # find lib/ + files/ locally or download them
files/
  99-sysctl-linux-optimizer.conf
  99-limits-linux-optimizer.conf
  99-sshd-linux-optimizer.conf
scripts/
  ubuntu-optimizer.sh       # thin per-distro wrappers, kept for old one-liners
  debian-optimizer.sh
  fedora-optimizer.sh
  centos-optimizer.sh       # also Alma / Rocky / CloudLinux
tests/
  run-tests.sh              # offline unit tests
```

---

## Contributing

Issues and PRs are welcome. Please run `bash tests/run-tests.sh` and keep `shellcheck` clean; if you add a step, add it to the `LO_STEPS` table in `lib/cli.sh` rather than hard-coding it into a menu.

## License

MIT — see [LICENSE](LICENSE).
