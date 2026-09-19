#!/bin/bash
# Linux Optimizer — command line, step table and interactive menu.
# Sourced last by every entry point; exposes lo_cli_main "$@".

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
LO_RUN_KERNEL=0
LO_RUN_PLAN=()
LO_SKIP_LIST=()
LO_SHOW_LIST=0
LO_SHOW_HELP=0

lo_usage() {
    cat <<EOF
Linux Optimizer v${LO_VERSION}

  --all              Every safe step: update, packages, swap, sysctl, ssh,
                     limits, hosts, dns, timezone, firewall
  --kernel           Install the XanMod kernel (Debian/Ubuntu only).
                     Risky on VMs and NVIDIA/VirtualBox DKMS hosts — see README
  --step NAME        Run one step (see --list). Repeatable.
  --skip NAME        Skip a step that --all would otherwise run. Repeatable.
  --list             List step names and exit
  --yes              Never ask for confirmation
  --no-reboot        Never reboot (default: ask once at the end)
  --reboot           Reboot when done without asking
  --swap-size SIZE   Swapfile size: 2G / 1G / 512M (default: auto by RAM)
  --dns "A B"        Fallback DNS servers (default: "1.1.1.1 8.8.8.8")
  --ssh-port PORT    Force the SSH port instead of parsing sshd_config
  --log FILE         Log file (default: /var/log/linux-optimizer.log)
  --non-interactive  No prompts at all; implies --yes --no-reboot
  --version          Print version and exit
  -h, --help         This text

Examples:
  bash linux-optimizer.sh --all
  bash linux-optimizer.sh --step sysctl --step ssh --yes
  bash linux-optimizer.sh --all --skip firewall --no-reboot
  bash linux-optimizer.sh --all --kernel --reboot
EOF
}

lo_parse_args() {
    while (($#)); do
        case "$1" in
            --all)             LO_RUN_PLAN=(__all) ;;
            --kernel)          LO_RUN_KERNEL=1 ;;
            --step)            LO_RUN_PLAN+=("${2:?--step needs a name}"); shift ;;
            --skip)            LO_SKIP_LIST+=("${2:?--skip needs a name}"); shift ;;
            --list)            LO_SHOW_LIST=1 ;;
            --yes)             LO_ASSUME_YES=1 ;;
            --no-reboot)       LO_REBOOT=no ;;
            --reboot)          LO_REBOOT=yes ;;
            --swap-size)       SWAP_SIZE="${2:?--swap-size needs a value}"; shift ;;
            --dns)             LO_DNS_SERVERS="${2:?--dns needs a value}"; shift ;;
            --ssh-port)        SSH_PORT="${2:?--ssh-port needs a number}"; shift ;;
            --log)             LO_LOG_FILE="${2:?--log needs a path}"; shift ;;
            --non-interactive) LO_NON_INTERACTIVE=1; LO_ASSUME_YES=1; LO_REBOOT=no ;;
            --version)         echo "linux-optimizer ${LO_VERSION}"; exit 0 ;;
            -h | --help)       LO_SHOW_HELP=1 ;;
            *)                 echo "Unknown option: $1" >&2; LO_SHOW_HELP=1 ;;
        esac
        shift
    done
    # SWAP_SIZE / LO_DNS_SERVERS / SSH_PORT are consumed by lib/optimize.sh
    export LO_REBOOT LO_ASSUME_YES LO_NON_INTERACTIVE LO_LOG_FILE SWAP_SIZE LO_DNS_SERVERS SSH_PORT
}

# ---------------------------------------------------------------------------
# Step table — one place, used by --all, --step, --list and the menu.
#   name | family filter | description | function
# ---------------------------------------------------------------------------
LO_STEPS=(
    "update|all|Complete update & clean the OS|complete_update"
    "ads|debian|Disable Ubuntu terminal adverts|disable_terminal_ads"
    "packages|all|Install useful packages & enable services|lo_cmd_packages"
    "swap|all|Create / enable the swapfile|swap_maker"
    "sysctl|all|Optimize network & kernel (sysctl drop-in)|sysctl_optimizations"
    "ssh|all|Optimize SSH (sshd drop-in — non-destructive)|ssh_optimizations"
    "limits|all|Optimize system limits (nofile/nproc/memlock)|limits_optimizations"
    "hosts|all|Fix /etc/hosts|fix_etc_hosts"
    "dns|all|Configure fallback DNS (resolved drop-in)|fix_dns"
    "timezone|all|Set timezone from the public IP|set_timezone"
    "firewall|all|Install & configure UFW|ufw_optimizations"
    "kernel|debian|Install the XanMod kernel (risky on VMs)|install_xanmod"
)

LO_ALL_SAFE_STEPS=(update ads packages swap sysctl ssh limits hosts dns timezone firewall)

lo_cmd_packages() { installations; enable_packages; }
lo_step_matches_family() { [[ "$1" == "all" || "$1" == "$OS_FAMILY" ]]; }

lo_list_steps() {
    local row name fam title fn
    printf '%-11s %-8s %s\n' "STEP" "NEEDS" "DESCRIPTION"
    printf '%-11s %-8s %s\n' "----" "-----" "-----------"
    for row in "${LO_STEPS[@]}"; do
        IFS='|' read -r name fam title fn <<<"$row"
        printf '%-11s %-8s %s\n' "$name" "$fam" "$title"
    done
}

lo_get_step() {
    local want="$1" row name fam title fn
    for row in "${LO_STEPS[@]}"; do
        IFS='|' read -r name fam title fn <<<"$row"
        [[ "$name" == "$want" ]] && { printf '%s|%s|%s' "$fn" "$fam" "$title"; return 0; }
    done
    return 1
}

lo_should_skip() {
    local s
    for s in "${LO_SKIP_LIST[@]:-}"; do [[ "$s" == "$1" ]] && return 0; done
    return 1
}

lo_run_step() {
    local name="$1" info fn fam title
    if ! info=$(lo_get_step "$name"); then
        red_msg "No such step: '$name'  (see --list)"
        return 1
    fi
    IFS='|' read -r fn fam title <<<"$info"
    if ! lo_step_matches_family "$fam"; then
        yellow_msg "Skipping '${title}' — not applicable on $(os_label)."
        return 0
    fi
    "$fn"
}

lo_run_plan() {
    local name
    for name in "$@"; do
        if lo_should_skip "$name"; then
            yellow_msg "Skipping '${name}' (--skip)."
            continue
        fi
        lo_run_step "$name" || red_msg "Step '${name}' reported a problem; continuing."
    done
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
lo_show_menu() {
    echo
    yellow_msg "Choose an option:"
    echo
    green_msg " 1  - Apply everything  (RECOMMENDED)"
    green_msg " 2  - Update & clean the OS only"
    green_msg " 3  - Install useful packages"
    green_msg " 4  - Swapfile + optimize network/SSH/limits"
    green_msg " 5  - Optimize network (sysctl) only"
    green_msg " 6  - Optimize SSH only"
    green_msg " 7  - Optimize system limits only"
    green_msg " 8  - Install & configure UFW"
    green_msg " 9  - Fix /etc/hosts + DNS + timezone"
    echo
    if [[ "$OS_FAMILY" == "debian" ]]; then
        green_msg " 10 - Install the XanMod kernel  (read the README notes first)"
    fi
    green_msg " s  - Show current settings & summary"
    green_msg " l  - List step names (for --step)"
    red_msg   " q  - Exit"
    echo
}

lo_main_menu() {
    local choice
    while true; do
        lo_show_menu
        read -r -p "Enter your choice: " choice || { echo; break; }
        echo
        case "$choice" in
            1)
                lo_run_plan "${LO_ALL_SAFE_STEPS[@]}"
                if [[ "$OS_FAMILY" == "debian" ]] && confirm "Also install the XanMod kernel now?"; then
                    lo_run_step kernel
                fi
                lo_summary
                ask_reboot
                break ;;
            2) complete_update ;;
            3) lo_cmd_packages ;;
            4) swap_maker; sysctl_optimizations; ssh_optimizations; limits_optimizations; ask_reboot; break ;;
            5) sysctl_optimizations ;;
            6) ssh_optimizations ;;
            7) limits_optimizations ;;
            8) ufw_optimizations ;;
            9) fix_etc_hosts; fix_dns; set_timezone ;;
            10)
                if [[ "$OS_FAMILY" == "debian" ]]; then
                    lo_run_step kernel; ask_reboot; break
                fi
                red_msg "Not available on this distro." ;;
            s | S) lo_summary ;;
            l | L) lo_list_steps ;;
            q | Q) echo; green_msg "Bye."; exit 0 ;;
            *) red_msg "Wrong input." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
lo_cli_main() {
    lo_parse_args "$@"

    if ((LO_SHOW_HELP)); then
        lo_usage
        return 0
    fi

    # The step table is static — --list must work without root and before OS
    # detection, so a user can audit what the script would do on any machine.
    if ((LO_SHOW_LIST)); then
        lo_list_steps
        return 0
    fi

    check_if_running_as_root
    detect_os || {
        red_msg "Unsupported operating system — open an issue if you think we should add it:"
        red_msg "  https://github.com/alimc98/linux-optimizer/issues"
        return 1
    }

    lo_banner "Detected: $(os_label)  ·  family=${OS_FAMILY}  ·  pkg=${PKG}"

    support_warning || return 1

    # Make sure the basics exist before touching anything.
    require_cmd curl wget sudo jq || pm_install curl wget sudo jq || true

    mkdir -p "$LO_BACKUP_DIR" 2>/dev/null || true
    if [[ "${LO_OFFLINE:-1}" != "1" ]]; then
        note_msg "Modules were downloaded to ${LO_DIR} — for a full audit use: git clone https://github.com/alimc98/linux-optimizer"
    fi

    if ((${#LO_RUN_PLAN[@]})); then
        if [[ "${LO_RUN_PLAN[0]}" == "__all" ]]; then
            lo_run_plan "${LO_ALL_SAFE_STEPS[@]}"
        else
            lo_run_plan "${LO_RUN_PLAN[@]}"
        fi
        ((LO_RUN_KERNEL)) && lo_run_step kernel
        lo_summary
        ask_reboot
        return 0
    fi

    lo_main_menu
    return 0
}
