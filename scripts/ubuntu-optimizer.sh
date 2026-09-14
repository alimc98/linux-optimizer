#!/bin/bash
# Linux Optimizer — Ubuntu entry point.
#
# Thin wrapper kept so the historical one-liners
#   wget .../scripts/ubuntu-optimizer.sh && bash ubuntu-optimizer.sh
# keep working. All real logic lives in lib/; this file only verifies the
# distro and hands control to the main script.
#
# https://github.com/hawshemi/linux-optimizer
set -o pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
LO_RAW_BASE="${LO_RAW_BASE:-https://raw.githubusercontent.com/hawshemi/linux-optimizer/main}"

_loader="$_here/lib/loader.sh"
if [[ ! -f "$_loader" ]]; then
    _loader="$(mktemp /tmp/lo-loader.XXXXXX)"
    curl -fsSL --max-time 45 -o "$_loader" "$LO_RAW_BASE/lib/loader.sh" 2>/dev/null \
        || wget -q -T 45 -O "$_loader" "$LO_RAW_BASE/lib/loader.sh" 2>/dev/null \
        || { echo "[!] Cannot reach $LO_RAW_BASE — use the git clone instead." >&2; exit 1; }
fi

# shellcheck source=/dev/null
source "$_loader"
lo_bootstrap || exit 1
lo_source_libs || exit 1

check_if_running_as_root
detect_os || exit 1

# shellcheck disable=SC2194  # the case word is intentionally a constant list

case "ubuntu " in
    *" $OS_ID "*) : ;;
    *)
        red_msg "This entry point is for Ubuntu, but you are running $(os_label)."
        echo
        yellow_msg "Use the main script instead — it auto-detects your distro:"
        green_msg "  bash linux-optimizer.sh"
        exit 1 ;;
esac

lo_banner "Ubuntu detected: $(os_label)"
export LO_RAW_BASE
exec bash "$LO_DIR/linux-optimizer.sh" "$@"
