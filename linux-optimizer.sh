#!/bin/bash
#
# Linux Optimizer — automate the boring, well-known tuning of a Linux server.
#
#   Ubuntu 22.04+ · Debian 12+ · Fedora 42+ · CentOS Stream / Alma / Rocky /
#   CloudLinux 8+
#
# One-liner (as root):
#   bash <(wget -qO- https://raw.githubusercontent.com/hawshemi/linux-optimizer/main/linux-optimizer.sh)
#
# ...but a real clone is safer (offline-capable, auditable before running):
#   git clone https://github.com/hawshemi/linux-optimizer && cd linux-optimizer && sudo bash linux-optimizer.sh
#
# MIT licensed. Read the README's NOTES before using --kernel.
#
set -o pipefail

# ---------------------------------------------------------------------------
# Bootstrap: find lib/ + files/ (locally, or fetch them), then load modules.
# ---------------------------------------------------------------------------
_self_dir() {
    local src="${BASH_SOURCE[0]}" target guard=0
    # NOTE: `src="$(readlink ... || break)"` would be an infinite loop — break
    # inside a command substitution only exits that subshell. Resolve manually.
    while [[ -L "$src" ]] && ((guard++ < 20)); do
        target="$(readlink "$src" 2>/dev/null)" || break
        case "$target" in
            /*) src="$target" ;;
            *)  src="$(dirname "$src")/$target" ;;
        esac
    done
    (cd "$(dirname "$src")" >/dev/null 2>&1 && pwd)
}

LO_ENTRY_DIR="$(_self_dir)"
LO_RAW_BASE="${LO_RAW_BASE:-https://raw.githubusercontent.com/hawshemi/linux-optimizer/main}"

_loader=""
for _cand in "$LO_ENTRY_DIR/lib/loader.sh" "$LO_ENTRY_DIR/../lib/loader.sh"; do
    [[ -f "$_cand" ]] && { _loader="$_cand"; break; }
done

if [[ -z "$_loader" ]]; then
    # Single downloaded file (curl|bash style): fetch the loader, let it get the rest.
    _loader="$(mktemp /tmp/lo-loader.XXXXXX)"
    if ! (command -v curl >/dev/null && curl -fsSL --max-time 45 -o "$_loader" "$LO_RAW_BASE/lib/loader.sh") \
       && ! (command -v wget >/dev/null && wget -q -T 45 -O "$_loader" "$LO_RAW_BASE/lib/loader.sh"); then
        echo "[!] Cannot reach $LO_RAW_BASE and lib/ is not next to this script." >&2
        echo "    Offline route: git clone https://github.com/hawshemi/linux-optimizer && cd linux-optimizer && bash linux-optimizer.sh" >&2
        exit 1
    fi
fi

# shellcheck source=/dev/null
source "$_loader"

lo_bootstrap || exit 1
lo_source_libs || exit 1

# Backups of any file we rewrite in place (the first copy is never overwritten).
export LO_BACKUP_DIR="${LO_BACKUP_DIR:-/root/linux-optimizer-backups}"

lo_cli_main "$@"
exit $?
