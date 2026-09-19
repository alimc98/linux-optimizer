#!/bin/bash
# Linux Optimizer — shared helpers
# https://github.com/alimc98/linux-optimizer
#
# Sourced by linux-optimizer.sh. Nothing here runs on source.

LO_VERSION="2.0.0"

# Bash 4+ is required (associative-free but ${var^^}, mapfile-free, arrays in
# conditionals). macOS ships bash 3.2 — tell the user instead of failing oddly.
if [[ -z "${BASH_VERSINFO:-}" || ${BASH_VERSINFO[0]} -lt 4 ]]; then
    echo "[!] Linux Optimizer needs bash >= 4. You have: ${BASH_VERSION:-unknown}." >&2
    echo "    On macOS: brew install bash   (this script targets Linux servers anyway)" >&2
    exit 1
fi

: "${LO_LOG_FILE:=/var/log/linux-optimizer.log}"
: "${LO_NON_INTERACTIVE:=0}"
: "${LO_ASSUME_YES:=0}"
: "${LO_REBOOT:=ask}"          # ask | no | yes
: "${LO_REBOOT_DELAY:=3}"
: "${LO_CONFIG_DIR:=/etc/linux-optimizer}"

# ---------------------------------------------------------------------------
# Colours / messages
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
    _LO_TPUT=1
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''; C_OFF=''
    _LO_TPUT=0
fi

# Pick a usable log file before anything tries to log. Root goes to /var/log,
# everybody else to a per-user temp file, and if even that fails we drop to
# /dev/null so the run never dies on a redirect.
_lo_init_log() {
    local wanted="${LO_LOG_FILE:-/var/log/linux-optimizer.log}" dir
    if [[ -w "$wanted" ]] || { dir="$(dirname "$wanted")"; [[ -d "$dir" && -w "$dir" ]]; }; then
        touch "$wanted" 2>/dev/null && return 0
    fi
    LO_LOG_FILE="${TMPDIR:-/tmp}/linux-optimizer-$(id -u 2>/dev/null || echo 0).log"
    touch "$LO_LOG_FILE" 2>/dev/null || LO_LOG_FILE=/dev/null
    return 0
}

_log() {
    # Redirection order matters: bash applies them left-to-right, so `2>/dev/null`
    # must come BEFORE the log-file append — otherwise a missing /var/log shows up
    # as a raw "No such file or directory" line on the user's terminal.
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(printf '%s' "$*" | sed -e "s/$(printf '\033')\[[0-9;]*m//g")" \
        2>/dev/null >>"$LO_LOG_FILE" || true
}

green_msg()  { echo "${C_GREEN}[*] ----- $*${C_OFF}"; _log "$*"; }
yellow_msg() { echo "${C_YELLOW}[*] ----- $*${C_OFF}"; _log "$*"; }
red_msg()    { echo "${C_RED}[!] ----- $*${C_OFF}" >&2; _log "ERROR: $*"; }
note_msg()   { echo "      $*"; _log "NOTE: $*"; }

# Print the banner
lo_banner() {
    echo
    green_msg "${C_BOLD}=========================================================${C_OFF}"
    green_msg " Linux Optimizer v${LO_VERSION} — https://github.com/alimc98/linux-optimizer"
    green_msg " ${1:-Tested on: Ubuntu 22.04+, Debian 12+, Fedora 42+, RHEL-family 8+}"
    green_msg " Root access is required. Read the README before option 1/2 (kernel)."
    green_msg "${C_BOLD}=========================================================${C_OFF}"
    echo
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
check_if_running_as_root() {
    # The offline test suite runs unprivileged; LO_ALLOW_NON_ROOT keeps the
    # message but does not exit. Production behaviour is unchanged.
    if [[ "${LO_ALLOW_NON_ROOT:-0}" == "1" && "${EUID}" -ne 0 ]]; then
        yellow_msg "Not root (test mode: LO_ALLOW_NON_ROOT=1)."
        return 0
    fi
    if [[ "${EUID}" -ne 0 ]]; then
        echo
        red_msg "Error: You must run this script as root! (try: sudo -i)"
        echo
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Command helpers
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Run a command, log it, return its status (never aborts the script).
run_quiet() {
    _log "RUN: $*"
    if "$@" >>"$LO_LOG_FILE" 2>&1; then
        return 0
    fi
    red_msg "Command failed: $*  (see ${LO_LOG_FILE})"
    return 1
}

require_cmd() {
    local missing=() c
    for c in "$@"; do
        have_cmd "$c" || missing+=("$c")
    done
    if ((${#missing[@]})); then
        red_msg "Missing required commands: ${missing[*]}"
        return 1
    fi
    return 0
}

# Retry a network command a few times — GitHub/CDN endpoints are flaky and
# unreachable from some networks on the first try.
retry() {
    local tries="${1:-3}" delay="${2:-2}" i rc=0
    shift 2
    for ((i = 1; i <= tries; i++)); do
        # NOTE: capture $? immediately — an `if "$@"; then ...; fi` compound
        # resets it to 0 when the condition fails, which made an earlier
        # version of this helper report success for a permanently failing cmd.
        "$@"
        rc=$?
        if ((rc == 0)); then
            return 0
        fi
        if ((i < tries)); then
            note_msg "attempt ${i}/${tries} failed (rc=${rc}): $* — retrying in ${delay}s"
            sleep "$delay"
        fi
    done
    red_msg "Giving up after ${tries} attempts: $*"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------
confirm() {
    # confirm "prompt text" → 0 = yes
    local prompt="${1:-Continue?}" ans
    if [[ "$LO_ASSUME_YES" == "1" || "$LO_NON_INTERACTIVE" == "1" ]]; then
        return 0
    fi
    printf '%s' "${C_YELLOW}[*] ----- ${prompt} (y/n) ${C_OFF}"
    read -r ans || ans="n"
    case "$ans" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

ask_reboot() {
    case "$LO_REBOOT" in
        no)  green_msg "Reboot skipped (--no-reboot). Reboot manually to apply kernel/sysctl changes."; return 0 ;;
        yes) yellow_msg "Rebooting in ${LO_REBOOT_DELAY}s (--reboot)..."; sleep "$LO_REBOOT_DELAY"; reboot; exit 0 ;;
    esac

    yellow_msg 'Reboot now? (Recommended) (y/n)'
    echo
    if [[ "$LO_NON_INTERACTIVE" == "1" ]]; then
        green_msg "Non-interactive mode: not rebooting."
        return 0
    fi
    local choice
    while true; do
        read -r choice || { echo; return 0; }
        case "$choice" in
            y | Y) sleep 0.5; reboot; exit 0 ;;
            n | N) break ;;
            *)     yellow_msg "Please answer y or n." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Small maths / sizing helpers
# ---------------------------------------------------------------------------
mem_total_mb() {
    local kb
    kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    [[ -z "$kb" ]] && kb=0
    echo $((kb / 1024))
}

# Clamp a number: clamp <min> <max> <value>
clamp() {
    local min="$1" max="$2" v="$3"
    ((v < min)) && v=$min
    ((v > max)) && v=$max
    echo "$v"
}

# Parse a human size (2G, 512M, 4096K) into bytes.
to_bytes() {
    local size="${1^^}" unit mult
    unit="${size: -1}"
    case "$unit" in
        K) mult=1024 ;;
        M) mult=$((1024 * 1024)) ;;
        G) mult=$((1024 * 1024 * 1024)) ;;
        B) mult=1 ;;
        [0-9]) unit=""; mult=1 ;;
        *) return 1 ;;
    esac
    local num="${size%[KMGB]}"
    [[ "$unit" == "" ]] && num="$size"
    [[ -z "$num" || ! "$num" =~ ^[0-9]+$ ]] && return 1
    echo $((num * mult))
}

# ---------------------------------------------------------------------------
# Managed-file writer
#
# Everything this script configures lives in its own drop-in file, so re-runs
# are idempotent and distro-owned files are never mangled:
#   /etc/sysctl.d/99-linux-optimizer.conf
#   /etc/security/limits.d/99-linux-optimizer.conf
#   /etc/ssh/sshd_config.d/99-linux-optimizer.conf
#   /etc/systemd/resolved.conf.d/99-linux-optimizer.conf
#
# backup_once <file>  → keeps the *first* (pristine) copy, never clobbers it
# ---------------------------------------------------------------------------
backup_once() {
    local src="$1" bak="${1}.pre-lo.bak"
    [[ -e "$src" ]] || return 0
    if [[ -e "$bak" ]]; then
        note_msg "backup already exists: $bak (kept)"
        return 0
    fi
    cp -a "$src" "$bak" && green_msg "Backed up: $src → $bak"
}

backup_first_of() {
    local src="$1"
    [[ -e "$src" ]] || return 0
    mkdir -p "$LO_BACKUP_DIR" 2>/dev/null || true
    local base stamp dest
    base="$(basename "$src")"
    stamp="$(date '+%Y%m%d-%H%M%S')"
    dest="${LO_BACKUP_DIR}/${stamp}-${base}"
    cp -a "$src" "$dest" 2>/dev/null && note_msg "backup: $dest"
}

# write_file_atomic <dest> <mode> <<< content-on-stdin
write_file_atomic() {
    local dest="$1" mode="${2:-0644}" tmp
    tmp="$(mktemp "${dest}.XXXXXX")" || return 1
    cat >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod "$mode" "$tmp"
    if ! mv -f "$tmp" "$dest"; then
        rm -f "$tmp"
        red_msg "Failed to write $dest"
        return 1
    fi
    note_msg "wrote $dest"
    return 0
}

# A stable, human-readable header for every managed file.
managed_header() {
    cat <<EOF
# ${1}
# Managed by Linux Optimizer v${LO_VERSION} — do not edit in place.
# Your own edits belong in a file that sorts AFTER this one
# (e.g. /etc/${2}/zz-local.conf) or in ${LO_CONFIG_DIR}/local/*.conf
# Source: https://github.com/alimc98/linux-optimizer
EOF
}
