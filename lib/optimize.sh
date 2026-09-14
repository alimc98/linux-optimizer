#!/bin/bash
# Linux Optimizer — the optimization modules, shared by every distro.
# Sourced by linux-optimizer.sh AFTER lib/common.sh and lib/detect.sh.
#
# Every module is a no-op-safe function: it writes a managed drop-in, never
# appends to distro files, and is idempotent (running twice = running once).
#
# Destinations are variables so a packager (or the test suite) can redirect
# them; the defaults are the FHS-correct system paths.

: "${LO_DIR:?LO_DIR must be set to the unpacked repo directory}"

: "${LO_SYSCTL_DROPIN:=/etc/sysctl.d/99-linux-optimizer.conf}"
: "${LO_SYSCTL_MAIN:=/etc/sysctl.conf}"
: "${LO_LIMITS_DROPIN:=/etc/security/limits.d/99-linux-optimizer.conf}"
: "${LO_SSHD_DROPIN:=/etc/ssh/sshd_config.d/99-linux-optimizer.conf}"
: "${LO_RESOLVED_DROPIN:=/etc/systemd/resolved.conf.d/99-linux-optimizer.conf}"
: "${LO_HOSTS_FILE:=/etc/hosts}"
: "${LO_RESOLV_FILE:=/etc/resolv.conf}"
: "${LO_FSTAB:=/etc/fstab}"
: "${LO_PROFILE:=/etc/profile}"
: "${LO_UFW_DEFAULT:=/etc/default/ufw}"
: "${LO_MOTD_NEWS:=/etc/default/motd-news}"
: "${LO_APT_KEYRING_DIR:=/etc/apt/keyrings}"
: "${LO_APT_SOURCE:=/etc/apt/sources.list.d/xanmod-release.list}"

# ---------------------------------------------------------------------------
# Package-manager wrappers
# ---------------------------------------------------------------------------
pm_update() {
    case "$OS_FAMILY" in
        debian) DEBIAN_FRONTEND=noninteractive apt-get update -qq ;;
        rhel)   dnf -y -q check-update >/dev/null 2>&1 || true ;;
    esac
}

pm_install() {
    local pkgs=("$@")
    ((${#pkgs[@]})) || return 0
    case "$OS_FAMILY" in
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${pkgs[@]}" \
                || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
            ;;
        rhel)
            dnf -y install "${pkgs[@]}"
            ;;
    esac
}

pkg_installed() {
    case "$OS_FAMILY" in
        debian) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
        rhel)   rpm -q "$1" >/dev/null 2>&1 ;;
    esac
}

complete_update() {
    echo
    yellow_msg "Updating the system... (this can take a while) — log: ${LO_LOG_FILE}"
    echo
    case "$OS_FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            run_quiet apt-get update -qq || true
            run_quiet apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade || true
            run_quiet apt-get -y dist-upgrade || true
            run_quiet apt-get -y autoremove --purge || true
            run_quiet apt-get autoclean || true
            ;;
        rhel)
            run_quiet dnf -y upgrade --exclude=kernel\* || run_quiet dnf -y upgrade || true
            run_quiet dnf -y autoremove || true
            run_quiet dnf clean all || true
            ;;
    esac
    echo
    green_msg "System updated & cleaned."
    echo
}

# ---------------------------------------------------------------------------
# Ubuntu "message of the day" adverts
# ---------------------------------------------------------------------------
disable_terminal_ads() {
    [[ "$OS_ID" == "ubuntu" ]] || return 0
    echo
    yellow_msg "Disabling Ubuntu terminal adverts (motd-news / apt-news)..."
    if [[ -f "$LO_MOTD_NEWS" ]]; then
        backup_once "$LO_MOTD_NEWS"
        sed -i 's/^ENABLED=.*/ENABLED=0/' "$LO_MOTD_NEWS"
    fi
    systemctl disable --now motd-news.timer motd-news.service >/dev/null 2>&1 || true
    have_cmd pro && run_quiet pro config set apt_news=false || true
    green_msg "Terminal adverts disabled."
    echo
}

# ---------------------------------------------------------------------------
# Useful packages
# ---------------------------------------------------------------------------
lo_packages_debian() {
    # Split so one unavailable name can't fail the whole transaction.
    pm_install ca-certificates curl wget gnupg lsb-release sudo jq
    pm_install bash-completion nano vim htop screen unzip zip dialog net-tools
    pm_install cron git make build-essential autoconf automake libtool pkg-config
    pm_install python3 python3-pip
    pm_install bc binutils busybox socat qrencode
    pm_install libssl-dev libsqlite3-dev libsodium-dev
    pm_install apt-transport-https apt-utils locales software-properties-common
    # Entropy & prefetch: haveged is only useful on old kernels (<4.8); modern
    # /dev/urandom never blocks. Install them but do not fail if absent.
    pm_install haveged preload || true
    pm_install ufw || true
}

lo_packages_rhel() {
    # EPEL first — ufw, dialog and friends live there on RHEL clones.
    if [[ "$OS_ID" == "fedora" ]]; then
        : # Fedora has everything in the main repos.
    else
        local epel_major="${OS_VERSION_MAJOR}"
        # Alma/Rocky 8 use epel 8, 9 -> 9, 10 -> 10; CentOS Stream 9 -> 9.
        [[ "$epel_major" =~ ^[0-9]+$ ]] || epel_major=9
        pkg_installed epel-release || run_quiet dnf -y install epel-release || \
            run_quiet rpm -ivh "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${epel_major}.noarch.rpm" || true
        run_quiet dnf -y install 'dnf-command(config-manager)' || run_quiet dnf -y install dnf-utils || true
    fi
    pm_install ca-certificates curl wget gnupg2 sudo jq
    pm_install bash-completion nano vim-enhanced htop screen unzip zip dialog net-tools
    pm_install cronie git make gcc gcc-c++ autoconf automake libtool pkgconf-pkg-config
    pm_install python3 python3-pip
    pm_install bc binutils socat qrencode
    pm_install openssl-devel libsodium-devel sqlite-devel || pm_install openssl-devel || true
    pm_install haveged || true
    pm_install ufw || true
}

installations() {
    echo
    yellow_msg "Installing useful packages..."
    echo
    case "$OS_FAMILY" in
        debian) lo_packages_debian ;;
        rhel)   lo_packages_rhel ;;
    esac
    echo
    green_msg "Useful packages installed (failures, if any, are in the log)."
    echo
}

enable_packages() {
    echo
    yellow_msg "Enabling services at boot..."
    local svc
    for svc in cron crond haveged preload; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 &&
           [[ -n "$(systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null)" ]]; then
            run_quiet systemctl enable "${svc}.service" || true
        fi
    done
    green_msg "Services enabled."
    echo
}

# ---------------------------------------------------------------------------
# XanMod kernel (Debian & Ubuntu only)
# ---------------------------------------------------------------------------
cpu_x86_64_level() {
    : "${LO_CPUINFO:=/proc/cpuinfo}"
    local level
    # Rewritten from the original `awk 'BEGIN{while(!/flags/) if (getline <
    # "/proc/cpuinfo" != 1) exit 1 ...}'` form for two reasons:
    #   1. it is now fixture-testable (LO_CPUINFO=<file>), and
    #   2. the original printed NOTHING and exited 1 when cpuinfo could not be
    #      read, which made the caller's `[ "" -ge 1 ]` blow up with
    #      "integer expression expected". We always print a number (0 = unknown).
    local cpu
    cpu="$(cat "$LO_CPUINFO" 2>/dev/null)" || cpu=""
    if [[ -z "$cpu" ]]; then
        echo 0; return 1
    fi
    level=$(printf '%s\n' "$cpu" | awk '
        BEGIN { done = 0 }
        !done && /^[[:space:]]*flags[[:space:]]*:/ {
            if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
            if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
            if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
            if (level == 3 && /avx512f/&&/avx512bw/&&/avx512cd/&&/avx512dq/&&/avx512vl/) level = 4
            done = 1
        }
        END { if (level > 0) print level; else print 0 }')
    [[ "$level" =~ ^[1-4]$ ]] || level=0
    echo "${level:-0}"
    ((level > 0))
}

is_container() {
    [[ -f /.dockerenv || -n "${container:-}" ]] && return 0
    systemd-detect-virt --container >/dev/null 2>&1 && return 0
    grep -qa 'docker\|lxc\|podman' /proc/1/cgroup 2>/dev/null
}

install_xanmod() {
    echo
    yellow_msg "Checking XanMod kernel..."

    if [[ "$OS_FAMILY" != "debian" ]]; then
        red_msg "XanMod only ships for Debian/Ubuntu. Skipping."
        return 1
    fi
    if is_container; then
        red_msg "You are inside a container — the kernel belongs to the host. Skipping XanMod."
        return 1
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        red_msg "XanMod repo is x86_64-only (arch: $(uname -m)). Skipping."
        return 1
    fi
    if uname -r | grep -q 'xanmod'; then
        green_msg "XanMod is already installed ($(uname -r))."
        return 0
    fi

    local virt
    virt=$(systemd-detect-virt 2>/dev/null || echo unknown)
    case "$virt" in
        kvm|qemu|oracle|xen|vmware|microsoft|bhyve)
            yellow_msg "Virtualised guest (${virt}). Kernel swaps can break VMs — see README note 3."
            confirm "Install XanMod anyway?" || { red_msg "XanMod skipped."; return 1; } ;;
    esac

    local level pkg
    level=$(cpu_x86_64_level)
    if ((level == 0)); then
        red_msg "Cannot determine the x86-64 microarchitecture level. Install XanMod manually — see xanmod.org."
        return 1
    fi
    yellow_msg "CPU microarchitecture level: x64v${level}"

    echo
    yellow_msg "Adding the XanMod APT repository (codename: ${OS_CODENAME})..."
    retry 3 2 pm_install wget curl gnupg ca-certificates lsb-release || true

    mkdir -p "$LO_APT_KEYRING_DIR"
    if ! retry 3 2 curl -fsSL --retry 2 -o /tmp/xanmod-archive.key https://dl.xanmod.org/archive.key; then
        red_msg "Could not download the XanMod signing key."
        return 1
    fi
    if ! gpg --dearmor < /tmp/xanmod-archive.key > "$LO_APT_KEYRING_DIR/xanmod-archive-keyring.gpg" 2>/dev/null; then
        red_msg "Could not dearmor the XanMod key."
        return 1
    fi
    rm -f /tmp/xanmod-archive.key

    # The repo moved from the old 'releases' suite to per-codename suites.
    echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${OS_CODENAME} main" \
        | write_file_atomic "$LO_APT_SOURCE" 0644

    if ! apt-get update -qq; then
        red_msg "XanMod repository is not reachable for '${OS_CODENAME}' — is this codename supported?"
        note_msg "Supported codenames: bookworm*, trixie, forky, sid, noble, plucky, questing, resolute and Ubuntu LTS names (*oldstable gets the LTS branch only)."
        return 1
    fi

    # Pick the meta package: current branch exists on trixie/forky/sid/Ubuntu;
    # Debian oldstable (bookworm) only carries linux-xanmod-lts-*.
    # The repo ships meta packages linux-xanmod-{,edge-,lts-,rt-}x64vN.
    # x64v1 exists only on the LTS branch; v2/v3 on both. Probe in that order.
    local cands=()
    if ((level >= 3)); then
        cands=(linux-xanmod-x64v3 linux-xanmod-lts-x64v3 linux-xanmod-lts-x64v2)
    elif ((level == 2)); then
        cands=(linux-xanmod-x64v2 linux-xanmod-lts-x64v2 linux-xanmod-lts-x64v1)
    else
        cands=(linux-xanmod-lts-x64v1)
    fi
    local c
    for c in "${cands[@]}"; do
        if apt-cache show "$c" >/dev/null 2>&1; then
            pkg="$c"
            [[ "$c" == *lts* ]] && yellow_msg "Using the LTS branch package: $c"
            break
        fi
    done
    if [[ -z "${pkg:-}" ]]; then
        red_msg "No XanMod package found for ${OS_CODENAME} (cpu v${level})."
        return 1
    fi

    echo
    yellow_msg "Installing ${pkg} (CPU level v${level})..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-headers-generic dkms libelf-dev >/dev/null 2>&1; then
        note_msg "Optional headers/dkms tooling not installed (non-fatal)."
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"; then
        red_msg "XanMod install failed — check ${LO_LOG_FILE}. The system is still on its original kernel."
        return 1
    fi

    echo
    green_msg "XanMod installed. REBOOT to apply it (GRUB will pick the newest kernel)."
    echo
}

# ---------------------------------------------------------------------------
# Swap file
# ---------------------------------------------------------------------------
default_swap_size() {
    local mb=$(( $(mem_total_mb) ))
    # 2GB, or RAM+2GB capped for hosts with <2GB RAM. A 1GB VPS does not want
    # a 2GB swapfile eating its only disk budget.
    if   ((mb < 1024)); then echo "1G"
    elif ((mb < 2048)); then echo "2G"
    else echo "2G"; fi
}

swap_maker() {
    : "${SWAP_PATH:=/swapfile}"
    : "${SWAP_SIZE:=$(default_swap_size)}"

    echo
    yellow_msg "Configuring swap (${SWAP_SIZE} at ${SWAP_PATH})..."

    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAP_PATH"; then
        green_msg "Swap already active at $SWAP_PATH — leaving it alone."
        return 0
    fi
    if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
        yellow_msg "Another swap device is already active: $(swapon --show=NAME --noheadings | tr '\n' ' ')"
        confirm "Create ${SWAP_PATH} anyway?" || { green_msg "Swap skipped."; return 0; }
    fi
    if [[ -f "$SWAP_PATH" ]]; then
        backup_once "$SWAP_PATH" || true
        swapoff "$SWAP_PATH" 2>/dev/null || true
        rm -f "$SWAP_PATH"
    fi

    local bytes
    bytes=$(to_bytes "$SWAP_SIZE") || { red_msg "Bad SWAP_SIZE: $SWAP_SIZE"; return 1; }

    # fallocate is instant but mkswap can misbehave on btrfs/xfs-with-reflink;
    # fall back to dd there.
    if ! fallocate -l "$bytes" "$SWAP_PATH" 2>/dev/null; then
        yellow_msg "fallocate failed (btrfs/xfs?); falling back to dd (slower)..."
        local mb=$((bytes / 1048576))
        dd if=/dev/zero of="$SWAP_PATH" bs=1M count="$mb" status=none || { red_msg "dd failed."; return 1; }
    fi
    chmod 600 "$SWAP_PATH"
    mkswap "$SWAP_PATH" >/dev/null || { red_msg "mkswap failed."; return 1; }
    swapon "$SWAP_PATH" || { red_msg "swapon failed."; return 1; }

    # fstab: replace an old entry, otherwise append (never duplicate).
    backup_once "$LO_FSTAB"
    sed -i "\#^[^#].*[[:space:]]${SWAP_PATH}[[:space:]]#d" "$LO_FSTAB"
    echo "$SWAP_PATH none swap sw,pri=10 0 0" >>"$LO_FSTAB"

    # On btrfs the file must be NoCOW+compressed=off or swapon fails.
    if findmnt -no FSTYPE -T "$SWAP_PATH" 2>/dev/null | grep -q btrfs; then
        chattr +C "$SWAP_PATH" 2>/dev/null || true
    fi

    green_msg "SWAP created and enabled ($(free -h | awk '/^Swap:/{print $2}'))."
    echo
}

# ---------------------------------------------------------------------------
# Sysctl (drop-in file, no more sed-on-/etc/sysctl.conf ping-pong)
# ---------------------------------------------------------------------------
sysctl_optimizations() {
    echo
    yellow_msg "Applying network & kernel tuning..."

    mkdir -p "$(dirname "$LO_SYSCTL_DROPIN")"
    if ! cp "$LO_DIR/files/99-sysctl-linux-optimizer.conf" "$LO_SYSCTL_DROPIN"; then
        red_msg "Could not install the sysctl drop-in."; return 1
    fi

    # Clean up after older versions of this script, which appended the same
    # block to /etc/sysctl.conf on EVERY run.
    if [[ -f "$LO_SYSCTL_MAIN" ]] && grep -q 'Linux-Optimizer/blob/main/files/sysctl.conf' "$LO_SYSCTL_MAIN"; then
        backup_once "$LO_SYSCTL_MAIN"
        sed -i -e '/# \/etc\/sysctl.conf/d' \
               -e '/These parameters in this file will be added/d' \
               -e '/hawshemi\/Linux-Optimizer/d' \
               -e '/^######/d' "$LO_SYSCTL_MAIN"
        green_msg "Removed the stale optimizer block from /etc/sysctl.conf (backup kept)."
    fi

    # Apply. In containers / locked-down kernels some keys simply do not exist
    # or are read-only, and procfs rejects them one at a time — report exactly
    # which, but do not treat that as a failed run.
    if have_cmd sysctl; then
        local out failed
        out="$(sysctl --system 2>&1 || true)"
        failed="$(printf '%s\n' "$out" | grep -iE 'cannot allocate|permission denied|No such file|unknown key' | head -10)"
        if [[ -n "$failed" ]]; then
            note_msg "Some sysctl keys were rejected (normal in containers / on kernels without them):"
            printf '%s\n' "$failed" | while IFS= read -r l; do note_msg "  $l"; done
        fi
    fi
    green_msg "Network & kernel tuning applied → $LO_SYSCTL_DROPIN"
    echo
}

# ---------------------------------------------------------------------------
# SSH (drop-in in sshd_config.d — original config untouched)
# ---------------------------------------------------------------------------
: "${SSH_PATH:=/etc/ssh/sshd_config}"

find_ssh_port() {
    [[ -n "$SSH_PORT" ]] && return 0
    SSH_PORT=22
    if [[ -f "$SSH_PATH" ]]; then
        # sshd takes the FIRST occurrence of Port, and drop-ins are read first.
        local p
        p=$(awk '/^[[:space:]]*[Pp]ort[[:space:]]+[0-9]+/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$SSH_PATH" 2>/dev/null)
        [[ -n "$p" ]] && SSH_PORT="$p"
    fi
    green_msg "SSH port: $SSH_PORT"
}

ssh_optimizations() {
    echo
    yellow_msg "Optimizing SSH (drop-in method — sshd_config is not modified)..."

    # OpenSSH >= 7.8 reads sshd_config.d/*.conf FIRST; first match wins, so a
    # drop-in always beats the main file. On older OpenSSH we append a marked
    # block instead — and strip that block before re-adding it, so it stays
    # idempotent (the old script appended, growing sshd_config on every run).
    # LO_SSHD_DROPIN_MODE=auto|dropin|append overrides the probe.
    local mode="${LO_SSHD_DROPIN_MODE:-auto}"
    if [[ "$mode" == "auto" ]]; then
        if have_cmd sshd && grep -qE '^[[:space:]]*#?[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSH_PATH" 2>/dev/null; then
            mode="dropin"
        else
            mode="append"
        fi
    fi
    if [[ "$mode" == "dropin" ]]; then
        mkdir -p "$(dirname "$LO_SSHD_DROPIN")"
        cp "$LO_DIR/files/99-sshd-linux-optimizer.conf" "$LO_SSHD_DROPIN"
    else
        yellow_msg "This OpenSSH has no sshd_config.d support — cleaning the old block & appending."
        rm -f "$LO_SSHD_DROPIN"
        backup_once "$SSH_PATH"
        local mark="# >>> Linux Optimizer >>>"
        sed -i "/^# >>> Linux Optimizer >>>/,/^# <<< Linux Optimizer <<</d" "$SSH_PATH"
        {
            echo "$mark"
            sed 's/#.*//' "$LO_DIR/files/99-sshd-linux-optimizer.conf" | grep -v '^[[:space:]]*$'
            echo "# <<< Linux Optimizer <<<"
        } >>"$SSH_PATH"
    fi

    # The old script rewrote Ciphers/UseDNS/Compression in the main file; undo
    # only its exact signatures so we never touch a hand-written config.
    if grep -q 'aes256-ctr,chacha20-poly1305@openssh.com' "$SSH_PATH" 2>/dev/null; then
        backup_once "$SSH_PATH"
        sed -i '/^Ciphers aes256-ctr,chacha20-poly1305@openssh.com$/d' "$SSH_PATH"
        note_msg "removed the legacy Ciphers line (the drop-in now owns it)."
    fi

    # NEVER restart sshd on an untested config — a typo here locks the operator
    # out of a remote box. sshd -t validates the whole tree including drop-ins.
    if ! lo_sshd_test; then
        red_msg "sshd -t failed AFTER applying our drop-in. Rolling it back so you do not get locked out."
        rm -f "$LO_SSHD_DROPIN"
        [[ -f "${SSH_PATH}.pre-lo.bak" ]] && cp -a "${SSH_PATH}.pre-lo.bak" "$SSH_PATH"
        lo_sshd_test || red_msg "sshd config is STILL invalid — do not restart ssh until you fix it manually."
        return 1
    fi

    restart_ssh
    green_msg "SSH optimized → $LO_SSHD_DROPIN (service reloaded, existing sessions unaffected)."
    echo
}

# Validate the assembled sshd config. `sshd -t` covers drop-ins too.
# Tests / unusual installs may set LO_SSHD_TEST_CMD (e.g. "sshd -t -D -e").
lo_sshd_test() {
    if [[ "${LO_SKIP_SSHD_TEST:-0}" == "1" ]]; then
        note_msg "sshd -t skipped (LO_SKIP_SSHD_TEST=1)."
        return 0
    fi
    ${LO_SSHD_TEST_CMD:-sshd -t} 2>/dev/null
}

restart_ssh() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || true
    else
        systemctl restart sshd 2>/dev/null || service sshd restart 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Limits (drop-in, replaces the ulimit-in-/etc/profile disaster)
# ---------------------------------------------------------------------------
limits_optimizations() {
    echo
    yellow_msg "Applying system limits..."

    mkdir -p "$(dirname "$LO_LIMITS_DROPIN")"
    cp "$LO_DIR/files/99-limits-linux-optimizer.conf" "$LO_LIMITS_DROPIN"

    # Undo the old behaviour: those duplicated ulimit lines in /etc/profile.
    if [[ -f "$LO_PROFILE" ]] && grep -qE '^ulimit -[cdfilmnqstuvx]' "$LO_PROFILE"; then
        backup_once "$LO_PROFILE"
        sed -i '/^ulimit -[cdfilmnqstuvx]/d' "$LO_PROFILE"
        green_msg "Removed legacy 'ulimit' lines from /etc/profile (backup kept)."
    fi

    green_msg "Limits applied → $LO_LIMITS_DROPIN (new sessions only)."
    echo
}

# ---------------------------------------------------------------------------
# DNS — stop scribbling on /etc/resolv.conf (it is a symlink owned by
# resolved/NetworkManager on every modern distro and gets clobbered on boot).
# ---------------------------------------------------------------------------
resolved_running() {
    # Overridable for tests: whether systemd-resolved is active is a property of
    # the machine running the script (a CI runner may really have it active), so
    # tests must pin it to exercise both branches deterministically.
    if [[ -n "${LO_RESOLVED_ACTIVE:-}" ]]; then
        [[ "$LO_RESOLVED_ACTIVE" == "1" ]]
        return
    fi
    systemctl is-active systemd-resolved >/dev/null 2>&1
}

fix_dns() {
    : "${LO_DNS_SERVERS:=1.1.1.1 8.8.8.8}"
    echo
    yellow_msg "Configuring fallback DNS (${LO_DNS_SERVERS})..."

    if resolved_running; then
        mkdir -p "$(dirname "$LO_RESOLVED_DROPIN")"
        {
            managed_header "DNS (Linux Optimizer)" "systemd/resolved.conf.d"
            echo "[Resolve]"
            echo "DNS=${LO_DNS_SERVERS}"
            echo "FallbackDNS=9.9.9.9"
            echo "DNSOverTLS=opportunistic"
            echo "Cache=yes"
        } | write_file_atomic "$LO_RESOLVED_DROPIN" 0644
        systemctl restart systemd-resolved 2>/dev/null || true
        green_msg "DNS configured via systemd-resolved drop-in."
    else
        # No resolver manager: write a real resolv.conf (backed up once).
        if [[ -L "$LO_RESOLV_FILE" ]]; then
            yellow_msg "$LO_RESOLV_FILE is a symlink ($(readlink -f "$LO_RESOLV_FILE")) — leaving it alone."
            return 0
        fi
        backup_once "$LO_RESOLV_FILE"
        {
            echo "# Managed by Linux Optimizer (no systemd-resolved detected)"
            local ns
            for ns in $LO_DNS_SERVERS; do echo "nameserver $ns"; done
            echo "options edns0 timeout:1 attempts:2 rotate"
        } | write_file_atomic "$LO_RESOLV_FILE" 0644
        green_msg "$LO_RESOLV_FILE set (backup at ${LO_RESOLV_FILE}.pre-lo.bak)."
    fi
    echo
}

# ---------------------------------------------------------------------------
# /etc/hosts
# ---------------------------------------------------------------------------
fix_etc_hosts() {
    echo
    yellow_msg "Checking /etc/hosts..."
    local host fqdn
    host=$(hostname)
    fqdn=$(hostname -f 2>/dev/null || echo "$host")

    backup_once "$LO_HOSTS_FILE"

    if ! grep -qE "(^|[[:space:]])${host}([[:space:]]|$)" "$LO_HOSTS_FILE"; then
        # 127.0.1.1 is the Debian/Ubuntu convention; 127.0.0.2 is safer on
        # RHEL where 127.0.1.1 may not be routed — both resolve to loopback.
        echo "127.0.1.1 ${fqdn} ${host}" >>"$LO_HOSTS_FILE"
        green_msg "Added ${host} to $LO_HOSTS_FILE."
    else
        green_msg "$LO_HOSTS_FILE OK — no changes."
    fi
    echo
}

# ---------------------------------------------------------------------------
# Timezone from the public IP (three independent sources, majority vote)
# ---------------------------------------------------------------------------
set_timezone() {
    echo
    yellow_msg "Setting timezone from the server's public IP..."

    if [[ ! -s /etc/resolv.conf && ! -e /run/systemd/resolve/stub-resolv.conf ]]; then
        note_msg "No working resolver yet — skipping timezone detection."
        return 0
    fi

    local src ip info tz=() good=0
    for src in https://ipv4.icanhazip.com https://api.ipify.org https://ipv4.ident.me; do
        ip=$(curl -fsS --max-time 8 "$src" 2>/dev/null) || continue
        [[ -n "$ip" ]] || continue
        info=$(curl -fsS --max-time 8 "http://ip-api.com/json/${ip}?fields=status,timezone" 2>/dev/null) || continue
        tz+=("$(printf '%s' "$info" | sed -n 's/.*"timezone":"\([^"]*\)".*/\1/p')")
        good=$((good + 1))
    done

    if ((good == 0)); then
        red_msg "All geolocation sources failed — keeping the current timezone."
        return 1
    fi

    # pick the most frequent answer
    local count best="" bestn=0 t
    for t in "${tz[@]}"; do
        [[ -n "$t" ]] || continue
        count=$(printf '%s\n' "${tz[@]}" | grep -cx "$t")
        ((count > bestn)) && { best="$t"; bestn=$count; }
    done
    [[ -z "$best" ]] && best="${tz[0]}"

    if timedatectl set-timezone "$best" 2>/dev/null; then
        green_msg "Timezone set to ${best} (from ${bestn} source(s))."
    else
        ln -sf "/usr/share/zoneinfo/${best}" /etc/localtime
        echo "$best" >/etc/timezone 2>/dev/null || true
        green_msg "Timezone set to ${best} (via symlink)."
    fi
    echo
}

# ---------------------------------------------------------------------------
# Firewall (UFW everywhere; keep firewalld out of the way)
# ---------------------------------------------------------------------------
ufw_optimizations() {
    echo
    yellow_msg "Configuring the firewall (UFW)..."

    if ! have_cmd ufw; then
        yellow_msg "ufw is not available on $(os_label) — leaving the firewall untouched."
        note_msg "If you want a firewall: RHEL-family uses firewalld, Ubuntu uses ufw."
        return 0
    fi
    find_ssh_port

    # If a firewall is already running with rules, do not stomp on it.
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
        local existing
        existing=$(ufw status numbered 2>/dev/null | grep -c '^\[')
        if ((existing > 0)) && ! ufw status 2>/dev/null | grep -qi 'Linux Optimizer'; then
            yellow_msg "UFW is already active with ${existing} rule(s) that this script did not create."
            confirm "Replace them with the optimizer defaults (SSH, 80, 443)?" || {
                red_msg "Leaving your firewall rules as they are."; return 0; }
        fi
    fi

    if [[ "$OS_FAMILY" == "rhel" ]]; then
        systemctl disable --now firewalld >/dev/null 2>&1 || true
    fi

    run_quiet ufw default deny incoming
    run_quiet ufw default allow outgoing
    run_quiet ufw allow "${SSH_PORT}/tcp"   || red_msg "Could not open SSH port ${SSH_PORT}!"
    run_quiet ufw allow 80/tcp
    run_quiet ufw allow 443/tcp
    run_quiet ufw limit "${SSH_PORT}/tcp" comment "linux-optimizer"

    # Use the system sysctl so our /etc/sysctl.d values are the ones that apply.
    if [[ -f "$LO_UFW_DEFAULT" ]]; then
        backup_once "$LO_UFW_DEFAULT"
        sed -i 's#^SYSCTL_CONF=.*#SYSCTL_CONF="/etc/sysctl.conf"#' "$LO_UFW_DEFAULT"
    fi

    yes | ufw enable >/dev/null 2>&1 || true
    run_quiet ufw reload || true
    green_msg "UFW configured. Opened: ${SSH_PORT}/tcp, 80/tcp, 443/tcp (+ rate limit on SSH)."
    note_msg "Any other port you run (panel, WireGuard, 8080...) must be opened manually: ufw allow <port>/udp|tcp"
    echo
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
lo_summary() {
    echo
    green_msg "${C_BOLD}================ RESULTS ================${C_OFF}"
    printf '%s\n' "  OS           : $(os_label) [${OS_FAMILY}/${PKG}]"
    printf '%s\n' "  Kernel       : $(uname -r)"
    printf '%s\n' "  CPU level    : x64v$(cpu_x86_64_level)"
    printf '%s\n' "  Memory       : $(free -h | awk '/^Mem:/{print $2}') total, $(free -h | awk '/^Mem:/{print $7}') available"
    printf '%s\n' "  Swap         : $(free -h | awk '/^Swap:/{print $2}')"
    printf '%s\n' "  Congestion   : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf '%s\n' "  Qdisc        : $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    printf '%s\n' "  Timezone     : $(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '?')"
    printf '%s\n' "  Firewall     : $(have_cmd ufw && ufw status 2>/dev/null | head -1 || echo 'n/a')"
    printf '%s\n' "  Modules      : ${LO_DIR} ($([[ ${LO_OFFLINE:-1} == 1 ]] && echo "local tree" || echo "fetched copy"))"
    printf '%s\n' "  Log          : ${LO_LOG_FILE}"
    green_msg "${C_BOLD}==========================================${C_OFF}"
    echo
}
