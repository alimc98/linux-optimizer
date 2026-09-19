#!/bin/bash
# Linux Optimizer — module loader / bootstrap
#
# Every entry point (linux-optimizer.sh and scripts/<distro>-optimizer.sh)
# sources this file. It finds lib/ + files/ either next to the script (git
# clone / tarball) or downloads them, so a bare `wget` of one file still works.
#
# Sets LO_DIR and LO_OFFLINE, then sources common/detect/optimize.

LO_RAW_BASE="${LO_RAW_BASE:-https://raw.githubusercontent.com/alimc98/linux-optimizer/main}"
LO_MODULE_FILES=(
    lib/common.sh
    lib/detect.sh
    lib/optimize.sh
    files/99-sysctl-linux-optimizer.conf
    files/99-limits-linux-optimizer.conf
    files/99-sshd-linux-optimizer.conf
    lib/cli.sh
)

_lo_self_dir() {
    local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" target guard=0
    while [[ -L "$src" ]] && ((guard++ < 20)); do
        target="$(readlink "$src" 2>/dev/null)" || break
        case "$target" in
            /*) src="$target" ;;
            *)  src="$(dirname "$src")/$target" ;;
        esac
    done
    (cd "$(dirname "$src")" >/dev/null 2>&1 && pwd)
}

# Fetch a single module file, preferring curl and falling back to wget.
_lo_fetch() {
    local url="$1" dest="$2"
    mkdir -p "$(dirname "$dest")" || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 45 --retry 2 -o "$dest" "$url" && [[ -s "$dest" ]] && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 45 -t 2 -O "$dest" "$url" && [[ -s "$dest" ]] && return 0
    fi
    return 1
}

lo_bootstrap() {
    local here; here="$(_lo_self_dir)"

    # 1. Already unpacked? (repo clone, tarball, or the old per-file layout)
    local cand
    for cand in "$here" "$here/.." "$PWD"; do
        if [[ -f "$cand/lib/common.sh" && -f "$cand/lib/cli.sh" ]]; then
            LO_DIR="$cand"; export LO_OFFLINE=1
            return 0
        fi
    done

    # 2. Cache hit from a previous run?
    local cache="${LO_CACHE_DIR:-${TMPDIR:-/tmp}/linux-optimizer-cache}"
    if [[ -f "$cache/lib/common.sh" && -f "$cache/lib/cli.sh" ]]; then
        LO_DIR="$cache"; LO_OFFLINE=0
        return 0
    fi

    # 3. One tarball request is much friendlier than N raw requests.
    mkdir -p "$cache" || return 1
    local tgz="$cache/main.tgz"
    if _lo_fetch "https://codeload.github.com/alimc98/linux-optimizer/tar.gz/refs/heads/main" "$tgz"; then
        if tar xzf "$tgz" -C "$cache" --strip-components=1 2>/dev/null && [[ -f "$cache/lib/common.sh" ]]; then
            rm -f "$tgz"
            LO_DIR="$cache"; export LO_OFFLINE=0
            return 0
        fi
        rm -f "$tgz"
    fi

    # 4. Fall back to per-file raw downloads.
    local f
    for f in "${LO_MODULE_FILES[@]}"; do
        if ! _lo_fetch "$LO_RAW_BASE/$f" "$cache/$f"; then
            echo "[!] Could not download '$f' from $LO_RAW_BASE" >&2
            echo "    GitHub may be blocked on this network, or the branch moved." >&2
            echo "    Offline route: git clone https://github.com/hawshemi/linux-optimizer" >&2
            echo "                     cd linux-optimizer && bash linux-optimizer.sh" >&2
            return 1
        fi
    done
    LO_DIR="$cache"; export LO_OFFLINE=0
    return 0
}

lo_source_libs() {
    # shellcheck source=/dev/null
    source "$LO_DIR/lib/common.sh" || return 1
    # Must run before anything logs: /var/log is root-writable only, and a
    # failed redirect is noise the user does not need.
    _lo_init_log
    # shellcheck source=/dev/null
    source "$LO_DIR/lib/detect.sh" || return 1
    # shellcheck source=/dev/null
    source "$LO_DIR/lib/optimize.sh" || return 1
    # shellcheck source=/dev/null
    source "$LO_DIR/lib/cli.sh" || return 1
    return 0
}
