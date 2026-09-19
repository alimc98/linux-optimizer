#!/bin/bash
# Linux Optimizer — distro detection & support policy.
# Sourced by every entry point. Nothing here runs on source.

# ---------------------------------------------------------------------------
# Detect distro family, codename and version from /etc/os-release (+ -release
# files, because RHEL clones report ID_LIKE="rhel centos fedora" and CentOS
# Stream reports ID=centos — os-release alone is ambiguous).
#
# Sets: OS_ID OS_NAME OS_VERSION OS_VERSION_MAJOR OS_CODENAME OS_FAMILY PKG
# ---------------------------------------------------------------------------
detect_os() {
    OS_ID="unknown" OS_NAME="" OS_VERSION="" OS_VERSION_MAJOR="" OS_CODENAME=""
    OS_FAMILY="" PKG=""

    # Overridable for tests / chroots / container dry runs.
    : "${LO_OS_RELEASE:=/etc/os-release}"
    : "${LO_RELEASE_GLOB:=/etc/*-release}"

    if [[ ! -r "$LO_OS_RELEASE" ]]; then
        red_msg "$LO_OS_RELEASE is missing — unsupported system."
        return 1
    fi

    # shellcheck source=/dev/null disable=SC1090,SC1091,SC2034,SC2154
    . "$LO_OS_RELEASE"
    local _id="${ID:-unknown}" _name="${NAME:-$ID}" _ver="${VERSION_ID:-}"
    local _like="${ID_LIKE:-}" _code="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    local _major="${_ver%%.*}"

    OS_ID="$_id"; OS_NAME="$_name"; OS_VERSION="$_ver"
    OS_VERSION_MAJOR="$_major"; OS_CODENAME="$_code"

    # Family from ID first (explicit, because Fedora's ID_LIKE is e.g.
    # "anaconda" and RHEL's is "rhel centos fedora" — matching only ID_LIKE
    # loses them), then fall back to ID_LIKE for derivatives/clones.
    case " ${_id} " in
        *" ubuntu "*|*" debian "*) OS_FAMILY="debian" ;;
        *" fedora "*|*" rhel "*|*" centos "*|*" almalinux "*|*" rocky "*|*" cloudlinux "*|*" nobara "*)
            OS_FAMILY="rhel" ;;
    esac
    if [[ -z "$OS_FAMILY" ]]; then
        case " ${_like} " in
            *" fedora "*|*" rhel "*|*" centos "*|*" almalinux "*|*" rocky "*|*" cloudlinux "*)
                OS_FAMILY="rhel" ;;
            *" debian "*|*" ubuntu "*)
                OS_FAMILY="debian" ;;
        esac
    fi

    # Normalise a few well-known aliases so a derivative lands on the family
    # whose packages it actually uses.
    if [[ "$OS_FAMILY" == "debian" ]]; then
        case "$_id" in
            linuxmint|elementary|pop|zorin|peppermint|mx|deepin|uos) : ;;
        esac
    fi
    if [[ -z "$OS_FAMILY" ]]; then
        case " ${_id} " in
            *" linuxmint "*|*" elementary "*|*" pop "*|*" zorin "*|*" mx "*|*" deepin "*)
                OS_FAMILY="debian" ;;
            *" nobara "*|*" bazzite "*|*" rosa "*|*" alma "*|*" rockylinux "*)
                OS_FAMILY="rhel" ;;
        esac
    fi

    # Pin down which RHEL clone this actually is (packages differ: crond vs
    # cron, sshd vs ssh, epel vs nothing, dnf-plugins-core names...).
    # Match the pretty/product name, not the "centos" inside ID_LIKE.
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        local rel
        rel="$(printf '%s' "$_name $_ver" | tr '[:upper:]' '[:lower:]')"
        [[ -n "$rel" ]] || rel="$_id"
        if   [[ "$rel" == *cloudlinux* ]];        then OS_ID="cloudlinux"
        elif [[ "$rel" == *"centos stream"* ]];   then OS_ID="centos"
        elif [[ "$rel" == *almalinux* ]];         then OS_ID="almalinux"
        elif [[ "$rel" == *rocky* ]];             then OS_ID="rocky"
        elif [[ "$OS_ID" == fedora ]];            then : # keep fedora
        else                                          OS_ID="rhel"
        fi
    fi

    # Fedora/RHEL have no usable VERSION_CODENAME; leave it empty. The XanMod
    # logic needs one, and it only ever runs on the debian family.
    case "$OS_FAMILY" in
        debian) PKG="apt" ;;
        rhel)   PKG="dnf" ;;
        *)      OS_FAMILY="unknown"; PKG="" ;;
    esac

    export OS_ID OS_NAME OS_VERSION OS_VERSION_MAJOR OS_CODENAME OS_FAMILY PKG

    if [[ "$OS_FAMILY" == "unknown" ]]; then
        red_msg "Unrecognised distribution: ${OS_NAME} (${OS_ID}${OS_VERSION:+ $OS_VERSION})"
        return 1
    fi
    return 0
}

os_label() {
    if [[ -n "$OS_VERSION" ]]; then
        echo "${OS_NAME} ${OS_VERSION}"
    else
        echo "$OS_NAME"
    fi
}

# ---------------------------------------------------------------------------
# Support policy — warn loudly, but never block a user on an untested release.
# ---------------------------------------------------------------------------
support_warning() {
    local major="${OS_VERSION_MAJOR:-0}"
    case "$OS_FAMILY" in
        debian)
            if [[ "$OS_ID" == "ubuntu" ]] && ((major < 22)); then
                red_msg "Ubuntu ${major:-?} is outside the tested range (22.04+) and may be EOL. Continuing anyway."
            elif [[ "$OS_ID" == "debian" ]] && ((major < 12)); then
                red_msg "Debian ${major:-?} is outside the tested range (12+) and may be EOL. Continuing anyway."
            fi
            ;;
        rhel)
            if [[ "$OS_ID" == "fedora" ]] && ((major < 42)); then
                red_msg "Fedora ${major:-?} is likely EOL (this script targets 42+). Continuing anyway."
            elif [[ "$OS_ID" != "fedora" ]] && ((major < 8)); then
                red_msg "RHEL-family ${major:-?} is outside the tested range (8+). Continuing anyway."
            fi
            ;;
        *)
            red_msg "Unknown OS '${OS_NAME}'. Create an issue: https://github.com/alimc98/linux-optimizer/issues"
            return 1
            ;;
    esac
    return 0
}
