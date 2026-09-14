#!/usr/bin/env bash
#
# Linux Optimizer — offline unit tests.
#
# These run anywhere (CI, a laptop, git-bash) with no network, no root and no
# apt/dnf: every destination path is redirected into a throwaway sandbox, so we
# verify the *logic* — detection, sizing, idempotency, drop-in content — not
# the package manager.
#
#   bash tests/run-tests.sh
#
set -uo pipefail


REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/lo-tests.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }

assert_eq()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$3], got [$2]"; }
assert_true() { eval "$2" && ok "$1" || bad "$1" "${3:-condition failed: $2}"; }
assert_file() { [[ -f "$2" ]] && ok "$1" || bad "$1" "missing file: $2"; }
assert_grep() { grep -qE "$3" "$2" 2>/dev/null && ok "$1" || bad "$1" "$2 does not match /$3/"; }
assert_not()  { grep -qE "$3" "$2" 2>/dev/null && bad "$1" "$2 unexpectedly matches /$3/" || ok "$1"; }

# Silence colour + file logging noise from the library under test.
export TERM=dumb
export LO_LOG_FILE="$SANDBOX/test.log"
export LO_BACKUP_DIR="$SANDBOX/backups"

load_lib() {
    # shellcheck source=/dev/null
    LO_DIR="$REPO" bash -c "
        source '$REPO/lib/common.sh'
        source '$REPO/lib/detect.sh'
        source '$REPO/lib/optimize.sh'
        source '$REPO/lib/cli.sh'
        $1"
}

# ===========================================================================
echo "== lib/loader.sh — self-containment =="
# ===========================================================================
# A single-file download must still work: loader falls back to per-file fetch.
# We simulate by pointing LO_RAW_BASE at a file:// URL of the repo tree.
mkdir -p "$SANDBOX/lonely"
cp "$REPO/linux-optimizer.sh" "$SANDBOX/lonely/"
if [[ -d "$SANDBOX/lonely/lib" ]]; then bad "lonely dir must not contain lib/"; else ok "single-file layout has no lib/"; fi

# loader's local-tree probe must reject that dir (no lib) rather than source nothing.
out="$(cd "$SANDBOX/lonely" && LO_RAW_BASE="http://127.0.0.1:1/nope" bash linux-optimizer.sh --version 2>&1)"
rc=$?
if [[ $rc -ne 0 && "$out" == *"Cannot reach"* ]]; then
    ok "unreachable mirror fails with a clear, actionable error"
else
    bad "unreachable mirror handling" "rc=$rc out=$out"
fi

# ===========================================================================
echo "== lib/detect.sh — distribution detection =="
# ===========================================================================
fixture() {
    local name="$1" extra="${2:-}"
    cat >"$SANDBOX/os-release-$name"
    if [[ -n "$extra" ]]; then
        mkdir -p "$SANDBOX/etc-$name"
        printf '%s\n' "$extra" > "$SANDBOX/etc-$name/system-release"
        echo "$SANDBOX/etc-$name/*-release"
    else
        echo "$SANDBOX/os-release-$name"   # placeholder, glob matches nothing extra
    fi
}

detect_case() {
    # shellcheck disable=SC2034  # label is documentation for the caller
    local label="$1" file="$2" glob="${3:-/dev/null}"
    local out
    out="$(LO_OS_RELEASE="$file" LO_RELEASE_GLOB="$glob" bash -c "
        source '$REPO/lib/common.sh' >/dev/null 2>&1
        source '$REPO/lib/detect.sh'
        detect_os || { echo 'RC=1'; exit 0; }
        printf '%s|%s|%s|%s|%s' \"\$OS_FAMILY\" \"\$OS_ID\" \"\$OS_VERSION_MAJOR\" \"\$OS_CODENAME\" \"\$PKG\"")"
    echo "$out"
}

mkdir -p "$SANDBOX/etc"

cat >"$SANDBOX/os-ubuntu24" <<'X'
NAME="Ubuntu"
VERSION="24.04 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
VERSION_ID="24.04"
VERSION_CODENAME=noble
X
r="$(detect_case ubuntu24 "$SANDBOX/os-ubuntu24")"
assert_eq "Ubuntu 24.04 → debian/ubuntu/24/noble/apt" "$r" "debian|ubuntu|24|noble|apt"

cat >"$SANDBOX/os-debian13" <<'X'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION_CODENAME=trixie
ID=debian
X
r="$(detect_case debian13 "$SANDBOX/os-debian13")"
assert_eq "Debian 13 → debian family, codename trixie" "$r" "debian|debian|13|trixie|apt"

cat >"$SANDBOX/os-debian11" <<'X'
NAME="Debian GNU/Linux"
VERSION_ID="11"
VERSION_CODENAME=bullseye
ID=debian
X
r="$(bash -c "LO_OS_RELEASE='$SANDBOX/os-debian11' LO_RELEASE_GLOB='/dev/null' bash -c '
  source $REPO/lib/common.sh; source $REPO/lib/detect.sh
  detect_os && { support_warning >/dev/null 2>&1 || true; support_warning 2>&1 | grep -q \"outside the tested range\" && echo WARNED; }'")"
assert_eq "Debian 11 (EOL) → warns but still resolves" "$r" "WARNED"

cat >"$SANDBOX/os-fedora43" <<'X'
NAME="Fedora Linux"
VERSION="43 (Server Edition)"
ID=fedora
VERSION_ID="43"
ID_LIKE="anaconda"
X
mkdir -p "$SANDBOX/etc-fedora"
printf 'Fedora release 43 (Forty Three)\n' > "$SANDBOX/etc-fedora/system-release"
r="$(detect_case fedora43 "$SANDBOX/os-fedora43" "$SANDBOX/etc-fedora/*-release")"
assert_eq "Fedora 43 → rhel/fedora/dnf" "$r" "rhel|fedora|43||dnf"

cat >"$SANDBOX/os-alma9" <<'X'
NAME="AlmaLinux"
VERSION="9.7 (Moss Grot)"
ID="almalinux"
ID_LIKE="rhel centos fedora"
VERSION_ID="9.7"
X
mkdir -p "$SANDBOX/etc-alma"
printf 'AlmaLinux release 9.7 (Moss Grot)\n' > "$SANDBOX/etc-alma/system-release"
r="$(detect_case alma9 "$SANDBOX/os-alma9" "$SANDBOX/etc-alma/*-release")"
assert_eq "AlmaLinux 9 → rhel/almalinux/9 (not mislabelled centos)" "$r" "rhel|almalinux|9||dnf"

cat >"$SANDBOX/os-rocky9" <<'X'
NAME="Rocky Linux"
VERSION="9.7 (Blue Ocelot)"
ID="rocky"
ID_LIKE="rhel centos fedora"
VERSION_ID="9.7"
X
mkdir -p "$SANDBOX/etc-rocky"
printf 'Rocky Linux release 9.7 (Blue Ocelot)\n' > "$SANDBOX/etc-rocky/system-release"
r="$(detect_case rocky9 "$SANDBOX/os-rocky9" "$SANDBOX/etc-rocky/*-release")"
assert_eq "Rocky 9 → rhel/rocky" "$r" "rhel|rocky|9||dnf"

cat >"$SANDBOX/os-stream10" <<'X'
NAME="CentOS Stream"
VERSION="10"
ID="centos"
ID_LIKE="rhel fedora"
VERSION_ID="10"
X
mkdir -p "$SANDBOX/etc-stream"
printf 'CentOS Stream release 10\n' > "$SANDBOX/etc-stream/system-release"
r="$(detect_case stream10 "$SANDBOX/os-stream10" "$SANDBOX/etc-stream/*-release")"
assert_eq "CentOS Stream 10 → rhel/centos/10" "$r" "rhel|centos|10||dnf"

cat >"$SANDBOX/os-cloudlinux" <<'X'
NAME="CloudLinux"
VERSION="9.6"
ID="cloudlinux"
ID_LIKE="rhel fedora centos anolis"
VERSION_ID="9.6"
X
mkdir -p "$SANDBOX/etc-cl"
printf 'CloudLinux release 9.6 (Final Frontier)\n' > "$SANDBOX/etc-cl/system-release"
r="$(detect_case cl "$SANDBOX/os-cloudlinux" "$SANDBOX/etc-cl/*-release")"
assert_eq "CloudLinux 9 → rhel/cloudlinux" "$r" "rhel|cloudlinux|9||dnf"

cat >"$SANDBOX/os-arch" <<'X'
NAME="Arch Linux"
ID=arch
BUILD_ID=rolling
X
r="$(detect_case arch "$SANDBOX/os-arch")"
assert_eq "Arch → unsupported (unknown family, rc!=0)" "$r" "RC=1"

r="$(LO_OS_RELEASE="$SANDBOX/definitely-missing" LO_RELEASE_GLOB=/dev/null bash -c "
    source '$REPO/lib/common.sh' >/dev/null 2>&1; source '$REPO/lib/detect.sh'
    detect_os || echo 'RC=1'")"
assert_eq "missing /etc/os-release → clean failure" "$r" "RC=1"

# ===========================================================================
echo "== lib/common.sh — helpers =="
# ===========================================================================
h() { bash -c "source '$REPO/lib/common.sh' >/dev/null 2>&1; $1"; }

assert_eq "to_bytes 2G"      "$(h 'to_bytes 2G')"  "2147483648"
assert_eq "to_bytes 512M"    "$(h 'to_bytes 512M')" "536870912"
assert_eq "to_bytes 1024K"   "$(h 'to_bytes 1024K')" "1048576"
assert_eq "to_bytes 4096B"   "$(h 'to_bytes 4096B')" "4096"
assert_eq "to_bytes bare 8192" "$(h 'to_bytes 8192')" "8192"
assert_eq "to_bytes lowercase 2g" "$(h 'to_bytes 2g')" "2147483648"
h 'to_bytes banana' >/dev/null 2>&1 && bad "to_bytes rejects garbage" || ok "to_bytes rejects garbage"
assert_eq "clamp low"  "$(h 'clamp 10 100 3')"  "10"
assert_eq "clamp high" "$(h 'clamp 10 100 300')" "100"
assert_eq "clamp mid"  "$(h 'clamp 10 100 55')"  "55"
assert_true "mem_total_mb > 0" '[[ $(h "mem_total_mb") -gt 0 ]]'
assert_eq "have_cmd finds bash" "$(h 'have_cmd bash && echo yes')" "yes"
assert_eq "have_cmd rejects nonsense" "$(h 'have_cmd definitely-not-a-cmd-xyz && echo yes || echo no')" "no"

# retry(): succeed on the 3rd attempt
cat >"$SANDBOX/flaky" <<'X'
#!/bin/bash
n=$(cat "$CNT" 2>/dev/null || echo 0); n=$((n+1)); echo $n >"$CNT"
[[ $n -ge 3 ]]
X
chmod +x "$SANDBOX/flaky"
out="$(CNT="$SANDBOX/cnt" LO_LOG_FILE="$SANDBOX/t.log" bash -c "
  source '$REPO/lib/common.sh' >/dev/null 2>&1
  retry 5 0 '$SANDBOX/flaky' && echo 'RECOVERED after '\$(cat '$SANDBOX/cnt')' attempts'" 2>/dev/null | tail -1)"
assert_eq "retry() recovers on the 3rd attempt" "$out" "RECOVERED after 3 attempts"
out="$(LO_LOG_FILE="$SANDBOX/t.log" bash -c "source '$REPO/lib/common.sh' >/dev/null 2>&1; retry 2 0 /bin/false && echo RESULT=ok || echo RESULT=gaveup" 2>&1 | grep '^RESULT=' | tail -1)"
assert_eq "retry() gives up after N tries" "$out" "RESULT=gaveup"

# backup_once must never clobber the first (pristine) copy
printf 'ORIGINAL\n' >"$SANDBOX/target"
LO_LOG_FILE="$SANDBOX/t.log" bash -c "source '$REPO/lib/common.sh' >/dev/null 2>&1; backup_once '$SANDBOX/target'"
printf 'MUTATED\n' >"$SANDBOX/target"
LO_LOG_FILE="$SANDBOX/t.log" bash -c "source '$REPO/lib/common.sh' >/dev/null 2>&1; backup_once '$SANDBOX/target'"
assert_eq "backup_once keeps the pristine copy on re-run" "$(cat "$SANDBOX/target.pre-lo.bak")" "ORIGINAL"

# ===========================================================================
echo "== lib/optimize.sh — sandboxed modules =="
# ===========================================================================
mk_sandbox_root() {
    mkdir -p "$SANDBOX/root/etc/sysctl.d" "$SANDBOX/root/etc/security/limits.d" \
             "$SANDBOX/root/etc/ssh/sshd_config.d" "$SANDBOX/root/etc/systemd/resolved.conf.d" \
             "$SANDBOX/root/proc"
}
mk_sandbox_root

run_opt() {
    local code="$1"
    LO_DIR="$REPO" \
    LO_OS_RELEASE="$SANDBOX/os-ubuntu24" LO_RELEASE_GLOB="$SANDBOX/os-ubuntu24" \
    LO_SYSCTL_DROPIN="$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf" \
    LO_SYSCTL_MAIN="$SANDBOX/root/etc/sysctl.conf" \
    LO_LIMITS_DROPIN="$SANDBOX/root/etc/security/limits.d/99-linux-optimizer.conf" \
    LO_SSHD_DROPIN="$SANDBOX/root/etc/ssh/sshd_config.d/99-linux-optimizer.conf" \
    LO_RESOLVED_DROPIN="$SANDBOX/root/etc/systemd/resolved.conf.d/99-linux-optimizer.conf" \
    LO_HOSTS_FILE="$SANDBOX/root/etc/hosts" \
    LO_RESOLV_FILE="$SANDBOX/root/etc/resolv.conf" \
    LO_FSTAB="$SANDBOX/root/etc/fstab" \
    LO_PROFILE="$SANDBOX/root/etc/profile" \
    LO_MOTD_NEWS="$SANDBOX/root/etc/default/motd-news" \
    LO_UFW_DEFAULT="$SANDBOX/root/etc/default/ufw" \
    LO_CPUINFO="${LO_CPUINFO:-$SANDBOX/cpuinfo}" \
    SSH_PATH="$SANDBOX/root/etc/ssh/sshd_config" \
    LO_SKIP_SSHD_TEST=1 LO_SSHD_DROPIN_MODE="${LO_SSHD_DROPIN_MODE:-dropin}" \
    LO_REBOOT=no LO_ASSUME_YES=1 \
    bash -c "$code"
}

PRELUDE="source '$REPO/lib/common.sh'; source '$REPO/lib/detect.sh'; source '$REPO/lib/optimize.sh'; detect_os >/dev/null"

# ---- hosts -----------------------------------------------------------
printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n' > "$SANDBOX/root/etc/hosts"
run_opt "$PRELUDE; fix_etc_hosts" >/dev/null
assert_grep "hosts: hostname appended" "$SANDBOX/root/etc/hosts" "$(hostname)|127\.0\.1\.1"
before="$(cat "$SANDBOX/root/etc/hosts")"
run_opt "$PRELUDE; fix_etc_hosts" >/dev/null
run_opt "$PRELUDE; fix_etc_hosts" >/dev/null
after="$(cat "$SANDBOX/root/etc/hosts")"
assert_eq "hosts: running 3x is idempotent" "$after" "$before"

# ---- DNS -------------------------------------------------------------
# Two branches, and which one runs depends on the *machine* (a CI runner may
# really have systemd-resolved active), so pin LO_RESOLVED_ACTIVE per case.
# Branch A: no resolved -> write a real resolv.conf, back the original up.
printf 'nameserver 192.168.1.1\n' > "$SANDBOX/root/etc/resolv.conf"
run_opt "LO_RESOLVED_ACTIVE=0; $PRELUDE; fix_dns" >/dev/null
assert_grep "dns: fallback servers written" "$SANDBOX/root/etc/resolv.conf" "nameserver 1\.1\.1\.1"
assert_grep "dns: original kept as backup" "$SANDBOX/root/etc/resolv.conf.pre-lo.bak" "192\.168\.1\.1"
assert_not "dns: no resolved drop-in written" "$SANDBOX/root/etc/systemd/resolved.conf.d/99-linux-optimizer.conf" "DNS="

# Branch B: resolved active -> drop-in only, /etc/resolv.conf untouched.
printf 'nameserver 192.168.1.1\n' > "$SANDBOX/root/etc/resolv.conf"
run_opt "LO_RESOLVED_ACTIVE=1; $PRELUDE; fix_dns" >/dev/null
assert_grep "dns: resolved drop-in written" "$SANDBOX/root/etc/systemd/resolved.conf.d/99-linux-optimizer.conf" "^DNS=1\.1\.1\.1 8\.8\.8\.8"
assert_grep "dns: resolved drop-in sets DoT opportunistic" "$SANDBOX/root/etc/systemd/resolved.conf.d/99-linux-optimizer.conf" "^DNSOverTLS=opportunistic"
assert_not "dns: resolv.conf left alone when resolved is active" "$SANDBOX/root/etc/resolv.conf" "1\.1\.1\.1"

cp "$SANDBOX/root/etc/resolv.conf" "$SANDBOX/resolv.real"
printf 'nameserver 127.0.0.53\noptions edns0\n' > "$SANDBOX/stub-resolv.conf"
rm -f "$SANDBOX/root/etc/resolv.conf"
if ln -s "$SANDBOX/stub-resolv.conf" "$SANDBOX/root/etc/resolv.conf" 2>/dev/null && [[ -L "$SANDBOX/root/etc/resolv.conf" ]]; then
    run_opt "LO_RESOLVED_ACTIVE=0; $PRELUDE; fix_dns" >"$SANDBOX/sym.out" 2>&1
    assert_grep "dns: leaves a resolved-managed symlink alone" "$SANDBOX/sym.out" "is a symlink"
    assert_not "dns: symlink target was not overwritten" "$SANDBOX/stub-resolv.conf" "1\.1\.1\.1"
else
    ok "dns: symlink case skipped on this platform (no symlink support)"
fi
rm -f "$SANDBOX/root/etc/resolv.conf"; cp "$SANDBOX/resolv.real" "$SANDBOX/root/etc/resolv.conf"

# ---- sysctl ----------------------------------------------------------
run_opt "$PRELUDE; sysctl_optimizations" >/dev/null 2>&1
assert_file "sysctl: drop-in installed" "$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf"
assert_grep "sysctl: BBR selected" "$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf" "^net\.ipv4\.tcp_congestion_control = bbr"
assert_grep "sysctl: fq qdisc" "$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf" "^net\.core\.default_qdisc = fq"
assert_grep "sysctl: tcp_mem is in PAGES, not bytes" "$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf" "^net\.ipv4\.tcp_mem = [0-9]+ [0-9]+ 1572864"
assert_grep "sysctl: overcommit is heuristic (0)" "$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf" "^vm\.overcommit_memory = 0"
assert_grep "sysctl: swappiness reduced" "$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf" "^vm\.swappiness = 1"
assert_not "sysctl: IPv6 NOT disabled" "$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf" "^[^#]*disable_ipv6 = 1"
assert_grep "sysctl: panic waits long enough to read" "$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf" "^kernel\.panic = 10"
# the 67108864 fs.file-max was > INT_MAX and got silently clamped
assert_not "sysctl: no impossible fs.file-max" "$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf" "fs\.file-max = 67108864"
run_opt "$PRELUDE; sysctl_optimizations" >/dev/null 2>&1
n1="$(grep -c 'tcp_congestion_control' "$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf")"
run_opt "$PRELUDE; sysctl_optimizations" >/dev/null 2>&1
n2="$(grep -c 'tcp_congestion_control' "$SANDBOX/root/etc/sysctl.d/99-linux-optimizer.conf")"
assert_eq "sysctl: 3 runs → still exactly one definition" "$n2" "$n1"
assert_eq "sysctl: exactly one tcp_congestion_control line" "$n2" "1"

# legacy /etc/sysctl.conf polluted by the old script → must be cleaned, backed up
{
  echo "# /etc/sysctl.conf"
  echo "fs.file-max = 67108864"
  echo "# Read More: https://github.com/hawshemi/Linux-Optimizer/blob/main/files/sysctl.conf"
  echo "######"
} > "$SANDBOX/root/etc/sysctl.conf"
run_opt "$PRELUDE; sysctl_optimizations" >/dev/null 2>&1
assert_not "sysctl: legacy block removed from /etc/sysctl.conf" "$SANDBOX/root/etc/sysctl.conf" "hawshemi/Linux-Optimizer"
assert_file "sysctl: legacy /etc/sysctl.conf was backed up" "$SANDBOX/root/etc/sysctl.conf.pre-lo.bak"

# ---- limits ----------------------------------------------------------
run_opt "$PRELUDE; limits_optimizations" >/dev/null 2>&1
assert_file "limits: drop-in installed" "$SANDBOX/root/etc/security/limits.d/99-linux-optimizer.conf"
assert_grep "limits: nofile 1048576 hard" "$SANDBOX/root/etc/security/limits.d/99-linux-optimizer.conf" "^\\* +hard +nofile +1048576"
# the old script appended 13 ulimit lines to /etc/profile on EVERY run
printf 'ulimit -n 1048576\nulimit -c unlimited\nexport PATH=/bin\n' > "$SANDBOX/root/etc/profile"
run_opt "$PRELUDE; limits_optimizations" >/dev/null 2>&1
assert_not "limits: legacy ulimit lines purged from /etc/profile" "$SANDBOX/root/etc/profile" "^ulimit -"
assert_grep "limits: unrelated profile content preserved" "$SANDBOX/root/etc/profile" "^export PATH=/bin"
assert_file "limits: /etc/profile backed up first" "$SANDBOX/root/etc/profile.pre-lo.bak"

# ---- ssh -------------------------------------------------------------
cat >"$SANDBOX/root/etc/ssh/sshd_config" <<'X'
Port 2222
PermitRootLogin yes
Ciphers aes256-ctr,chacha20-poly1305@openssh.com
X
run_opt "$PRELUDE; find_ssh_port" 2>&1 | grep -q "2222" && ok "ssh: parses a custom Port (2222)" || bad "ssh: custom port parse"
run_opt "$PRELUDE; ssh_optimizations" >/dev/null 2>&1
assert_file "ssh: drop-in installed (main file untouched)" "$SANDBOX/root/etc/ssh/sshd_config.d/99-linux-optimizer.conf"
assert_grep "ssh: UseDNS no in drop-in" "$SANDBOX/root/etc/ssh/sshd_config.d/99-linux-optimizer.conf" "^UseDNS no"
assert_grep "ssh: ClientAlive is actually sane" "$SANDBOX/root/etc/ssh/sshd_config.d/99-linux-optimizer.conf" "^ClientAliveInterval 60"
assert_grep "ssh: GatewayPorts locked down" "$SANDBOX/root/etc/ssh/sshd_config.d/99-linux-optimizer.conf" "^GatewayPorts no"
assert_grep "ssh: legacy Ciphers line removed from sshd_config" "$SANDBOX/root/etc/ssh/sshd_config" "^Port 2222"
assert_not "ssh: legacy Ciphers line gone" "$SANDBOX/root/etc/ssh/sshd_config" "^Ciphers aes256-ctr,chacha20"
assert_grep "ssh: user's PermitRootLogin preserved" "$SANDBOX/root/etc/ssh/sshd_config" "^PermitRootLogin yes"
assert_not "ssh: main file never accumulated appends" "$SANDBOX/root/etc/ssh/sshd_config" "^TCPKeepAlive"

# append mode (old OpenSSH without sshd_config.d): marked block, and re-runs
# must not grow the file
LO_SSHD_DROPIN_MODE=append run_opt "$PRELUDE; ssh_optimizations" >/dev/null 2>&1
LO_SSHD_DROPIN_MODE=append run_opt "$PRELUDE; ssh_optimizations" >/dev/null 2>&1
LO_SSHD_DROPIN_MODE=append run_opt "$PRELUDE; ssh_optimizations" >/dev/null 2>&1
n="$(grep -c '^TCPKeepAlive yes' "$SANDBOX/root/etc/ssh/sshd_config")"
assert_eq "ssh: append mode is idempotent across 3 runs" "$n" "1"
assert_grep "ssh: append mode writes the marked block" "$SANDBOX/root/etc/ssh/sshd_config" "Linux Optimizer"
assert_grep "ssh: append mode still preserves user directives" "$SANDBOX/root/etc/ssh/sshd_config" "^PermitRootLogin yes"
cat >"$SANDBOX/root/etc/ssh/sshd_config" <<'X'
Port 2222
PermitRootLogin yes
X

# broken sshd config must roll back rather than restart an unusable daemon
export BROKEN=1
out="$(LO_DIR="$REPO" LO_SSHD_TEST_CMD='/bin/false' \
  LO_SSHD_DROPIN="$SANDBOX/root/etc/ssh/sshd_config.d/99-linux-optimizer.conf" \
  SSH_PATH="$SANDBOX/root/etc/ssh/sshd_config" LO_BACKUP_DIR="$SANDBOX/backups" \
  LO_LOG_FILE="$SANDBOX/t.log" bash -c "
    source '$REPO/lib/common.sh'; source '$REPO/lib/detect.sh'; source '$REPO/lib/optimize.sh'
    ssh_optimizations >/dev/null 2>&1 || echo ROLLED_BACK")"
echo "$out" | grep -q ROLLED_BACK && ok "ssh: invalid config rolls back instead of restarting sshd" || bad "ssh rollback" "$out"

# ---- cpu level -------------------------------------------------------
cat >"$SANDBOX/cpuinfo" <<'X'
processor	: 0
vendor_id	: GenuineIntel
model name	: Intel(R) Xeon(R) Platinum 8375C
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 ss syscall nx pdpe1gb rdtscp lm constant_tsc arch_perfmon rep_good nopl xtopology tsc_reliable nonstop_tsc cpuid pni pclmulqdq ssse3 fma cx16 pdcm pcid sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand hypervisor lahf_lm abm 3dnowprefetch cpuid_fault invpcid_single ssbd ibrs ibpb stibp ibrs_enhanced fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid avx512f avx512dq rdseed adx smap avx512ifma clflushopt clwb avx512cd sha_ni avx512bw avx512vl xsaveopt xsavec xgetbv1 arat avx512vbmi umip pku ospke avx512_vbmi2 gfni vaes movdiri
X
lv="$(run_opt "$PRELUDE; cpu_x86_64_level" | tail -1)"
assert_eq "cpu level: AVX-512 host → v4" "$lv" "4"
cat >"$SANDBOX/cpuinfo.l2" <<'X'
processor	: 0
vendor_id	: GenuineIntel
model name	: Intel(R) Xeon(R) CPU E5-2680 v4
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 ss syscall nx pdpe1gb rdtscp lm constant_tsc rep_good nopl xtopology nonstop_tsc cpuid pni pclmulqdq ssse3 fma cx16 pcid sse4_1 sse4_2 x2apic movbe popcnt aes xsave avx f16c rdrand hypervisor lahf_lm abm 3dnowprefetch invpcid_single ssbd ibrs fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid movbe xsave xsaveopt arat fma abm
X
lv="$(LO_CPUINFO="$SANDBOX/cpuinfo.l2" run_opt "$PRELUDE; cpu_x86_64_level" 2>/dev/null | tail -1)"
assert_eq "cpu level: AVX2 host (no AVX-512) → v3" "$lv" "3"
cat >"$SANDBOX/cpuinfo.v2" <<'X'
processor	: 0
flags		: fpu vme de pse tsc msr pae mce cx8 apic mca cmov pat clflush mmx fxsr sse sse2 ss syscall nx lm constant_tsc popcnt sse4_1 sse4_2 ssse3 cx16 lahf
X
lv="$(LO_CPUINFO="$SANDBOX/cpuinfo.v2" run_opt "$PRELUDE; cpu_x86_64_level" 2>/dev/null | tail -1)"
assert_eq "cpu level: SSE4-era host → v2" "$lv" "2"
lv="$(LO_CPUINFO="$SANDBOX/missing-cpuinfo" run_opt "$PRELUDE; cpu_x86_64_level" 2>/dev/null | tail -1)"
assert_eq "cpu level: unreadable /proc/cpuinfo → 0 (safe skip)" "$lv" "0"

# ---- swap sizing -----------------------------------------------------
sz="$(run_opt "$PRELUDE; default_swap_size")"
case "$sz" in [1-9]*[GM]) ok "swap size auto → $sz";; *) bad "swap size auto" "got '$sz'";; esac
assert_eq "to_bytes on the auto size works" "$(h "to_bytes $sz" >/dev/null && echo yes)" "yes"

# ---- ubuntu adverts --------------------------------------------------
mkdir -p "$SANDBOX/root/etc/default"
printf 'ENABLED=1\n' > "$SANDBOX/root/etc/default/motd-news"
run_opt "$PRELUDE; disable_terminal_ads" >/dev/null 2>&1
assert_eq "ads: motd-news ENABLED=1 → 0" "$(sed -n 's/^ENABLED=//p' "$SANDBOX/root/etc/default/motd-news")" "0"
# and it must be a no-op on non-Ubuntu
out="$(LO_OS_RELEASE="$SANDBOX/os-debian13" LO_DIR="$REPO" bash -c "
  source '$REPO/lib/common.sh'; source '$REPO/lib/detect.sh'; source '$REPO/lib/optimize.sh'
  LO_MOTD_NEWS='$SANDBOX/root/etc/default/motd-news' detect_os >/dev/null; disable_terminal_ads; echo DONE")"
echo "$out" | grep -q DONE && ok "ads: runs quietly on Debian too (function is distro-guarded)"

# ===========================================================================
echo "== lib/cli.sh — step table & args =="
# ===========================================================================
out="$(LO_ALLOW_NON_ROOT=1 LO_DIR="$REPO" bash "$REPO/linux-optimizer.sh" --version)"
assert_eq "--version prints the version" "$out" "linux-optimizer $(grep -m1 '^LO_VERSION=' "$REPO/lib/common.sh" | tr -d '"' | cut -d= -f2)"

list="$(LO_ALLOW_NON_ROOT=1 LO_OS_RELEASE="$SANDBOX/os-ubuntu24" LO_RELEASE_GLOB="$SANDBOX/os-ubuntu24" \
        bash "$REPO/linux-optimizer.sh" --list 2>/dev/null || true)"
for step in update packages swap sysctl ssh limits hosts dns timezone firewall kernel; do
    echo "$list" | grep -qE "^$step " && ok "--list contains step '$step'" || bad "--list missing '$step'"
done
echo "$list" | grep -qE '^ads +debian' && ok "--list marks 'ads' as debian-only" || bad "--list ads filter"

out="$(LO_ALLOW_NON_ROOT=1 LO_REBOOT=no LO_OS_RELEASE="$SANDBOX/os-ubuntu24" LO_RELEASE_GLOB=/dev/null \
      bash "$REPO/linux-optimizer.sh" --step definitely-not-a-step 2>&1 </dev/null || true)"
echo "$out" | grep -q "No such step" && ok "--step with a bogus name errors clearly" || bad "--step validation" "$out"

# every declared step function must actually exist
missing=0
# shellcheck disable=SC2034  # fam/title are read for readability, unused here
while IFS='|' read -r name fam title fn; do
    run_opt "$PRELUDE; source '$REPO/lib/cli.sh'; declare -F $fn >/dev/null || echo MISSING:$fn" | grep -q "MISSING:$fn" && { bad "step '$name' → function '$fn' not defined"; missing=1; }
done < <(LO_DIR="$REPO" bash -c "
    source '$REPO/lib/common.sh'; source '$REPO/lib/detect.sh'; source '$REPO/lib/optimize.sh'; source '$REPO/lib/cli.sh'
    for row in \"\${LO_STEPS[@]}\"; do echo \"\$row\"; done")
[[ $missing -eq 0 ]] && ok "all 12 step functions resolve" || true

# ===========================================================================
echo "== config files — sanity =="
# ===========================================================================
SYS="$REPO/files/99-sysctl-linux-optimizer.conf"
assert_true "sysctl: no duplicate keys in the shipped file" \
    "! grep -oE '^[a-z][a-z0-9._]+ *=' '$SYS' | sort | uniq -d | grep -q ." "duplicate sysctl keys: $(grep -oE '^[a-z][a-z0-9._]+ *=' "$SYS" | sort | uniq -d | tr '\n' ' ')"
assert_true "sysctl: every assignment parses as k = v" \
    "! grep -E '^[a-z][a-z0-9._]+ *= ' '$SYS' | awk -F= 'NF!=2 || \$2 !~ /^ +[^ ]/{bad=1} END{exit !bad}'"

LIM="$REPO/files/99-limits-linux-optimizer.conf"
assert_true "limits: domain/type/item triples are well formed" \
    "! grep -vE '^[[:space:]]*(#|$)' '$LIM' | awk 'NF!=4 && NF!=3 {bad=1} END{exit !bad}'"

SSHD="$REPO/files/99-sshd-linux-optimizer.conf"
assert_true "sshd: no directive appears twice" \
    "! grep -oE '^[A-Z][A-Za-z]+' '$SSHD' | sort | uniq -d | grep -q ."

for f in "$SYS" "$LIM" "$SSHD"; do
    [[ -s "$f" ]] && ok "$(basename "$f") present and non-empty" || bad "$(basename "$f") empty"
done

# shell syntax
for f in "$REPO"/linux-optimizer.sh "$REPO"/lib/*.sh "$REPO"/scripts/*.sh "$REPO"/tests/*.sh; do
    bash -n "$f" 2>/dev/null && ok "bash -n $(basename "$f")" || bad "bash -n $(basename "$f")"
done

# no CRLF anywhere (a \r breaks these on a real server)
if grep -rlU $'\r' --include='*.sh' --include='*.conf' "$REPO" 2>/dev/null | grep -q .; then
    bad "no CRLF line endings" "$(grep -rlU $'\r' --include='*.sh' --include='*.conf' "$REPO" 2>/dev/null | tr '\n' ' ')"
else
    ok "no CRLF line endings in .sh/.conf"
fi

# executable bits
for f in "$REPO/linux-optimizer.sh" "$REPO"/scripts/*.sh; do
    [[ -x "$f" ]] && ok "executable: $(basename "$f")" || bad "not executable: $f"
done

# ---- per-distro wrappers (regression: they used to reject their own distro) --
declare -A WRAP_OK=( [ubuntu]=ubuntu [debian]=debian [fedora]=fedora [centos]=rocky )
declare -A WRAP_FIX=(
    [ubuntu]='NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n'
    [debian]='NAME="Debian GNU/Linux"\nID=debian\nVERSION_ID="12"\nVERSION_CODENAME=bookworm\n'
    [fedora]='NAME="Fedora Linux"\nID=fedora\nVERSION_ID="42"\n'
    [rocky]='NAME="Rocky Linux"\nID="rocky"\nVERSION_ID="9.4"\n'
)
for w in ubuntu debian fedora centos; do
    for id in ubuntu debian fedora rocky; do
        printf '%b' "${WRAP_FIX[$id]}" > "$SANDBOX/os-$id"
        out="$(LO_ALLOW_NON_ROOT=1 LO_OS_RELEASE="$SANDBOX/os-$id" \
               bash "$REPO/scripts/$w-optimizer.sh" --list 2>&1 || true)"
        if [[ "$id" == "${WRAP_OK[$w]}" ]]; then
            grep -q "detected" <<<"$out" && ok "wrapper $w accepts $id" \
                || bad "wrapper $w rejects its own distro ($id)"
        else
            grep -q "This entry point is for" <<<"$out" && ok "wrapper $w rejects $id" \
                || bad "wrapper $w does not reject $id"
        fi
    done
done

# ---- sysctl file hygiene ----------------------------------------------
# /proc rejects anything it does not know, so every line must be a real,
# writable key. This one is mode 0444 in mainline and must never appear here.
grep -qE '^net\.ipv4\.tcp_available_congestion_control *=' "$REPO/files/99-sysctl-linux-optimizer.conf" \
    && bad "sysctl drop-in writes read-only tcp_available_congestion_control" \
    || ok "sysctl drop-in avoids read-only tcp_available_congestion_control"

# duplicated keys are silently last-wins, which hides mistakes
dupkeys="$(grep -oE '^[a-z][a-z0-9._]+ *=' "$REPO/files/99-sysctl-linux-optimizer.conf" | tr -d ' =' | sort | uniq -d)"
[[ -z "$dupkeys" ]] && ok "sysctl drop-in has no duplicate keys" \
    || bad "sysctl duplicate keys: $(tr '\n' ' ' <<<"$dupkeys")"

# ===========================================================================
echo
echo "------------------------------------------------------------"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
echo "------------------------------------------------------------"
[[ $FAIL -eq 0 ]]
