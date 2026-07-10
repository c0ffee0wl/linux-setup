#!/bin/bash

# Linux Setup Script
# Configures a fresh Kali Linux / Debian / Ubuntu installation with development tools and customizations

set -eo pipefail

# Deterministic, English command output regardless of the host locale (German,
# etc.) so parsed strings match (ufw "Status: active", apt-cache "Candidate:").
# C.UTF-8 is built into glibc (no locale-gen needed on stock/minimal VMs) and
# preserves UTF-8. Affects only this process, not the installed system's locale.
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

VERSION="2.13.1"
FORCE_MODE=false
NO_MODE=false
NO_HACKING_TOOLS=false
HARDEN_ONLY=false
NO_KEYBOARD_LAYOUT=false

# Colors for output (suppressed when not a TTY or when NO_COLOR is set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# Show usage information
show_usage() {
    cat << EOF
Linux Setup Script v${VERSION}
Configures a fresh Debian/Kali Linux installation with development tools and customizations

Usage: $0 [OPTIONS]

Options:
  --force, -f          Run in non-interactive mode, automatically answering 'Yes' to all prompts
  --yes, -y            Same as --force
  --no, -n             Run in non-interactive mode, automatically answering 'No' to all prompts
  --no-hacking-tools   Skip installation of hacking/pentest tools (even on Kali)
  --no-keyboard-layout Skip configuring the German XFCE keyboard layout (useful with --force)
  --harden-only        Apply only supply-chain hardening configs (no installs, no shell changes)
  --help, -h           Display this help message and exit

Interactive Mode (default):
  The script will prompt for confirmation on certain actions:
  - Overwriting existing .zshrc configuration
  - Changing default shell to zsh
  - Overwriting existing Terminator configuration
  - Overwriting existing PowerShell profile
  - Overwriting existing tmux configuration
  - Configuring German keyboard layout in XFCE (skip with --no-keyboard-layout)

Force/Yes Mode (--force, --yes, -f, -y):
  All prompts are automatically answered 'Yes'. Useful for:
  - Automated/unattended installations
  - CI/CD pipelines
  - Re-running the script to get updates without manual intervention

No Mode (--no, -n):
  All prompts are automatically answered 'No'. Useful for:
  - Installing packages without overwriting existing configurations
  - Running the script but skipping optional configurations

Harden-Only Mode (--harden-only):
  Applies supply-chain hardening configs without installing any packages.
  Writes package manager configs (npm, Bun, Cargo, uv, pip), system-level
  fallbacks, telemetry opt-outs, and Go module hardening env vars.
  Useful for hardening existing systems without a full setup run.

Examples:
  $0              # Interactive installation
  $0 --force      # Non-interactive installation (answer Yes to all)
  $0 --yes        # Same as --force
  $0 --no         # Non-interactive installation (answer No to all)
  $0 --harden-only  # Apply supply-chain hardening configs only

EOF
    exit 0
}

# Preserve original args before parsing consumes them via shift.
# Used by self-update (exec "$0") to re-run with the same flags.
ORIGINAL_ARGS=("$@")

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f|--yes|-y)
            FORCE_MODE=true
            shift
            ;;
        --no|-n)
            NO_MODE=true
            shift
            ;;
        --no-hacking-tools)
            NO_HACKING_TOOLS=true
            shift
            ;;
        --no-keyboard-layout)
            NO_KEYBOARD_LAYOUT=true
            shift
            ;;
        --harden-only)
            HARDEN_ONLY=true
            shift
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option '$1'${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Optional source-built tools that failed to build/install this run (OOM on
# low-RAM VMs, transient network/upstream errors). Collected here and reported at
# the end; the run continues rather than aborting because every source-built tool
# is optional and the embedded .zshrc guards each one at runtime.
FAILED_BUILDS=()
note_build_failure() {
    warn "$1 failed to install (continuing without it) - the shell config guards its absence"
    FAILED_BUILDS+=("$1")
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    warn "This script should normally not be run as root. Please run as a regular user with sudo privileges."
fi

# Check if we're on a Debian-based system (hard requirement)
if ! grep -qE "(debian|ID_LIKE.*debian)" /etc/os-release 2>/dev/null; then
    error "This script requires a Debian-based Linux distribution. Detected system is not compatible."
fi

# Backup a file with timestamp (--sudo for root-owned paths)
backup_file() {
    local sudo_cmd=""
    if [ "$1" = "--sudo" ]; then sudo_cmd="sudo"; shift; fi
    local file_path="$1"
    if [ -f "$file_path" ]; then
        local backup_path="${file_path}.backup.$(date +'%Y-%m-%d_%H-%M-%S')"
        $sudo_cmd cp "$file_path" "$backup_path"
        log "Backed up to: $backup_path"
    fi
}

# Write a config file from stdin, only when its content differs from what is
# already there; back up the previous version first. Unchanged files are left
# untouched so re-runs cause no backup churn.
# Usage: write_config_file [--sudo] <dest> << 'EOF' ... EOF
write_config_file() {
    local sudo_cmd=""
    if [ "$1" = "--sudo" ]; then sudo_cmd="sudo"; shift; fi
    local dest="$1" tmp
    tmp=$(mktemp)
    cat > "$tmp"    # heredoc stdin into a real file (never install /dev/stdin)
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 0
    fi
    backup_file ${sudo_cmd:+--sudo} "$dest"
    $sudo_cmd install -m 644 "$tmp" "$dest"
    rm -f "$tmp"
}

# apt-get wrapper: in force/no mode run fully non-interactively so debconf
# dialogs, dpkg conffile prompts, and Ubuntu's needrestart menu can't stall
# unattended runs. sudo resets the environment, so the variables are passed
# on sudo's command line rather than exported. DPkg::Lock::Timeout makes apt
# wait for the lock instead of aborting when a boot-time apt job (cloud-init,
# apt-daily, unattended-upgrades) still holds it - the classic cloud-init race.
apt_get() {
    if [[ "$FORCE_MODE" == "true" || "$NO_MODE" == "true" ]]; then
        sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
            -o DPkg::Lock::Timeout=300 \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
    else
        sudo apt-get -o DPkg::Lock::Timeout=300 "$@"
    fi
}

# True when the vendor publishes an apt suite at <base_url>/dists/<suite>/Release.
# Used to pick a repo suite by capability instead of maintaining codename lists
# (Docker and PowerShell repos); bounded timeouts so an unreachable mirror
# can't stall the run.
repo_suite_published() {
    curl --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 15 -fsI \
        "$1/dists/$2/Release" > /dev/null 2>&1
}

# Prompt user with yes/no question
# Usage: prompt_yes_no "Question?" "Y" (or "N" for default No)
# Returns: 0 for yes, 1 for no
prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local response

    # In force mode, automatically answer yes
    if [[ "$FORCE_MODE" == "true" ]]; then
        log "Force mode: Auto-answering 'Yes' to: $prompt"
        return 0
    fi

    # In no mode, automatically answer no
    if [[ "$NO_MODE" == "true" ]]; then
        log "No mode: Auto-answering 'No' to: $prompt"
        return 1
    fi

    if [[ "$default" == "Y" ]]; then
        read -p "$prompt (Y/n): " response
        response=${response:-Y}
    else
        read -p "$prompt (y/N): " response
        response=${response:-N}
    fi

    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Check if we're on Kali Linux (preferred but not required)
is_kali_linux() {
    grep -q "Kali" /etc/os-release 2>/dev/null
}

# Check if we're on Ubuntu or Ubuntu-based distribution
is_ubuntu() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        [ "$ID" = "ubuntu" ] || [ "$ID_LIKE" = "ubuntu" ] || echo "$ID_LIKE" | grep -q "ubuntu"
    else
        return 1
    fi
}

# Update or add a single export in ~/.profile (idempotent)
# Uses grep to check existence, sed to update in place, or appends if new
#
# Usage: update_profile_export <var_name> <var_value>
#   var_name:  Environment variable name (e.g., DO_NOT_TRACK)
#   var_value: Value to set (will be quoted in the export)
#
# Returns: 0 on success
update_profile_export() {
    local var_name="$1"
    local var_value="$2"
    local profile_file="$HOME/.profile"

    # Create file if it doesn't exist
    [ ! -f "$profile_file" ] && touch "$profile_file"

    # Escape special characters for shell double-quoted string:
    # - Backslashes must be escaped first (before other escapes add more)
    # - Double quotes, dollar signs, and backticks need escaping
    local escaped_value="$var_value"
    escaped_value="${escaped_value//\\/\\\\}"    # \ -> \\
    escaped_value="${escaped_value//\"/\\\"}"    # " -> \"
    escaped_value="${escaped_value//\$/\\\$}"    # $ -> \$
    escaped_value="${escaped_value//\`/\\\`}"    # ` -> \`

    # For sed replacement, also escape & (special in replacement string)
    local sed_value="$escaped_value"
    sed_value="${sed_value//&/\\&}"              # & -> \&

    if grep -q "^export ${var_name}=" "$profile_file" 2>/dev/null; then
        # Update existing export in place
        sed -i "s|^export ${var_name}=.*|export ${var_name}=\"${sed_value}\"|" "$profile_file"
    else
        # Append new export
        echo "export ${var_name}=\"${escaped_value}\"" >> "$profile_file"
    fi
}

# Ensure ~/.zprofile sources ~/.profile for ZSH compatibility
# ZSH doesn't read ~/.profile by default, so we add a source line
# This is idempotent - only adds the line if not already present
# Skips on Kali Linux (already sources .profile in default .zshrc)
#
# Usage: ensure_zprofile_sources_profile
ensure_zprofile_sources_profile() {
    # Kali Linux already sources .profile in its default ZSH config
    is_kali_linux && return 0

    local zprofile="$HOME/.zprofile"
    local source_line='[[ -f ~/.profile ]] && emulate sh -c "source ~/.profile"'

    # Create file if it doesn't exist
    [ ! -f "$zprofile" ] && touch "$zprofile"

    # Add source line if not present (using fixed string match)
    if ! grep -qF "$source_line" "$zprofile" 2>/dev/null; then
        echo "" >> "$zprofile"
        echo "# Source ~/.profile for environment variables (added by linux-setup)" >> "$zprofile"
        echo "$source_line" >> "$zprofile"
    fi
}

# Apply all supply-chain hardening configurations
# Writes package manager configs (user-level + system-level fallbacks),
# telemetry opt-outs, and Go module hardening environment variables.
# Safe to call on systems where tools are not yet installed.
apply_supply_chain_hardening() {
    log "Applying supply-chain hardening configurations..."

    # --- npm hardening (user-level) ---
    # Protects against npm being invoked directly or installed later;
    # bun already blocks lifecycle scripts via trustedDependencies model.
    # Cooldown units differ per tool: npm reads `min-release-age` in DAYS,
    # pnpm reads `minimum-release-age` (same ~/.npmrc) in MINUTES. 7 days ==
    # 10080 minutes; both match the uv/bun 7-day cooldown.
    log "Configuring npm security hardening..."
    write_config_file "$HOME/.npmrc" << 'EOF'
ignore-scripts=true
save-exact=true
audit=true
fund=false
min-release-age=7
minimum-release-age=10080
EOF

    # --- Bun hardening (user-level) ---
    log "Configuring Bun security hardening..."
    write_config_file "$HOME/.bunfig.toml" << 'EOF'
[install]
exact = true
saveTextLockfile = true
minimumReleaseAge = 604800
EOF

    # --- Cargo hardening (user-level, preserve existing) ---
    log "Configuring Cargo security hardening..."
    mkdir -p "$HOME/.cargo"
    if [ ! -f "$HOME/.cargo/config.toml" ]; then
        cat > "$HOME/.cargo/config.toml" << 'EOF'
[net]
git-fetch-with-cli = true
EOF
    fi

    # --- Python package manager hardening (user-level) ---
    log "Configuring Python package manager hardening..."
    mkdir -p "$HOME/.config/uv" "$HOME/.config/pip"

    write_config_file "$HOME/.config/uv/uv.toml" << 'EOF'
exclude-newer = "1 week"
system-certs = true
python-preference = "system"
EOF

    write_config_file "$HOME/.config/pip/pip.conf" << 'EOF'
[global]
prefer-binary = true

[install]
prefer-binary = true
EOF

    # --- System-level fallback configs (defence-in-depth) ---
    # If user deletes their dotfiles, system defaults still enforce hardening
    log "Deploying system-level fallback configs..."
    if sudo -n true 2>/dev/null; then
        sudo mkdir -p /usr/local/etc /etc/uv

        write_config_file --sudo /usr/local/etc/npmrc << 'EOF'
ignore-scripts=true
save-exact=true
audit=true
fund=false
min-release-age=7
minimum-release-age=10080
EOF

        write_config_file --sudo /etc/uv/uv.toml << 'EOF'
exclude-newer = "1 week"
system-certs = true
python-preference = "system"
EOF

        write_config_file --sudo /etc/pip.conf << 'EOF'
[global]
prefer-binary = true

[install]
prefer-binary = true
EOF

        log "System-level fallback configs deployed"
    else
        warn "Could not obtain passwordless sudo - skipping system-level fallback configs"
    fi

    # --- Telemetry/Privacy opt-outs ---
    log "Setting privacy/telemetry environment defaults..."

    # Universal opt-out signal (proposed standard)
    update_profile_export "DO_NOT_TRACK" "1"

    # .NET / PowerShell / Azure
    update_profile_export "DOTNET_CLI_TELEMETRY_OPTOUT" "1"
    update_profile_export "POWERSHELL_TELEMETRY_OPTOUT" "1"
    update_profile_export "AZURE_CORE_COLLECT_TELEMETRY" "0"

    # Scarf download-analytics gateway
    update_profile_export "SCARF_ANALYTICS" "false"

    # Hugging Face Hub (huggingface_hub, transformers, datasets)
    update_profile_export "HF_HUB_DISABLE_TELEMETRY" "1"

    # Go module supply-chain hardening
    update_profile_export "GOPROXY" "https://proxy.golang.org,off"
    update_profile_export "GOSUMDB" "sum.golang.org"

    # Go telemetry opt-out (Go 1.23+ writes mode to ~/.config/go/telemetry/mode)
    command -v go &>/dev/null && go telemetry off 2>/dev/null || true

    # Ensure ZSH sources ~/.profile on non-Kali systems
    ensure_zprofile_sources_profile

    log "Supply-chain hardening complete"
}

# Check if desktop environment is available
has_desktop_environment() {
    # Check for desktop session files (most reliable)
    if [ -d /usr/share/xsessions ] && [ -n "$(ls -A /usr/share/xsessions 2>/dev/null)" ]; then
        return 0
    fi

    if [ -d /usr/share/wayland-sessions ] && [ -n "$(ls -A /usr/share/wayland-sessions 2>/dev/null)" ]; then
        return 0
    fi

    # Check for display manager configuration
    if [ -f /etc/X11/default-display-manager ] && [ -s /etc/X11/default-display-manager ]; then
        return 0
    fi

    # Check for common DE packages (Kali uses XFCE)
    if dpkg -l 2>/dev/null | grep -qE '^ii\s+(xfce4|gnome-shell|kde-plasma-desktop|plasma-desktop|lxde-core)'; then
        return 0
    fi

    return 1
}

# Detect the terminal background, storing the result (dark|light|unknown) in the
# global TERMINAL_BG. Primary: OSC 11 query of the live terminal (what
# bat/neovim/fish use). Fallback: $COLORFGBG. The result is cached after the
# first call: the OSC query flips the tty into raw mode, so we only do it once.
# Sets a global (not echo) so callers must invoke it directly, not via $(...),
# which would run it in a subshell and discard the cache.
detect_terminal_background() {
    if [ -n "${TERMINAL_BG:-}" ]; then return 0; fi
    TERMINAL_BG="unknown"

    local r g b lum reply oldstty bg hr hg hb

    # Primary: ask the terminal for its background color (OSC 11, BEL-terminated).
    if [ -t 0 ] && [ -t 1 ] && [ -e /dev/tty ]; then
        oldstty=$(stty -g < /dev/tty 2>/dev/null) || oldstty=""
        if [ -n "$oldstty" ]; then
            # Restore the terminal if interrupted mid-query, so a Ctrl-C during
            # the read can't leave it stuck in raw/no-echo mode.
            trap 'stty "$oldstty" < /dev/tty 2>/dev/null; trap - INT TERM HUP; exit 130' INT TERM HUP
            stty raw -echo min 0 time 0 < /dev/tty 2>/dev/null || true
            printf '\033]11;?\007' > /dev/tty 2>/dev/null || true
            IFS= read -r -d $'\007' -t 1 reply < /dev/tty 2>/dev/null || true
            stty "$oldstty" < /dev/tty 2>/dev/null || true
            trap - INT TERM HUP

            # Reply looks like: ESC]11;rgb:RRRR/GGGG/BBBB
            if [[ "$reply" =~ rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+) ]]; then
                # Channels may be 1, 2, or 4 hex digits; normalize to 8-bit. A
                # 1-digit channel repeats (f -> ff = 255); wider forms keep their
                # top two digits (ffff -> ff, 2828 -> 28).
                hr=${BASH_REMATCH[1]}; hg=${BASH_REMATCH[2]}; hb=${BASH_REMATCH[3]}
                [ ${#hr} -eq 1 ] && hr=$hr$hr
                [ ${#hg} -eq 1 ] && hg=$hg$hg
                [ ${#hb} -eq 1 ] && hb=$hb$hb
                r=$((16#${hr:0:2})); g=$((16#${hg:0:2})); b=$((16#${hb:0:2}))
                lum=$(( (299*r + 587*g + 114*b) / 1000 ))   # BT.601, 0..255
                if [ "$lum" -lt 128 ]; then TERMINAL_BG="dark"; else TERMINAL_BG="light"; fi
            fi
        fi
    fi

    # Fallback: COLORFGBG = "fg;bg" (or "fg;default;bg"); low bg index => dark.
    # Require a ';' so a single-field (foreground-only) value isn't read as bg.
    if [ "$TERMINAL_BG" = "unknown" ] && [ -n "${COLORFGBG:-}" ] && [[ "$COLORFGBG" == *";"* ]]; then
        bg="${COLORFGBG##*;}"
        case "$bg" in
            0|1|2|3|4|5|6|8) TERMINAL_BG="dark" ;;
            7|9|1[0-5])      TERMINAL_BG="light" ;;
        esac
    fi

    return 0
}

# Convenience wrapper: true (0) only when the background is positively dark.
# Light OR undeterminable -> false, so callers that default to a light theme
# (e.g. bat's Coldark-Cold) keep it unless dark is positively detected.
is_dark_terminal() {
    detect_terminal_background
    [ "$TERMINAL_BG" = "dark" ]
}

# Convenience wrapper: true (0) only when the background is positively light.
# Undeterminable -> false, so callers that default to dark (e.g. the PowerShell
# profile) keep those defaults unless light is positively detected.
is_light_terminal() {
    detect_terminal_background
    [ "$TERMINAL_BG" = "light" ]
}

# Convert version string to comparable number: "1.85" -> 185, "" -> 0
version_to_num() {
    local v="${1:-0.0}"
    [ -z "$v" ] && v="0.0"
    echo "$v" | awk -F. '{print ($1 * 100) + $2}'
}

# Get installed Go version as comparable number (e.g., 1.24 -> 124, missing -> 0)
get_go_version() {
    if ! command -v go &> /dev/null; then
        echo "0"
        return
    fi
    local go_version=$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+' | head -1 || true)
    version_to_num "$go_version"
}

# Per-tool minimum apt versions (compared via version_to_num, e.g. "0.9" -> 9).
# Decide apt-vs-source per tool; keep in sync with the install calls further down.
ZOXIDE_MIN=9      # zoxide >= 0.9  (Kali/sid ship 0.9.x; Debian <=12 / Ubuntu 22.04 ship 0.4.3)
SD_MIN=7          # sd     >= 0.7  (bookworm's 0.7.6 is usable; older/absent -> build)
DELTA_MIN=16      # delta  >= 0.16 (Ubuntu 24.04 LTS ships 0.16.5)
LAZYGIT_MIN=50    # lazygit>= 0.50 (Debian 13 / Kali have it; older -> go install)
YQ_MIN=400        # yq-go  >= 4.0  (mikefarah yq; Kali/sid ship 4.53)
PWSH_MIN=700      # powershell >= 7.0 (Kali ships 7.5.x natively; else Microsoft repo)

# apt candidate version of a package as a comparable number (0 if not in archive)
apt_candidate_version_num() {
    local v
    v=$(apt-cache policy "$1" 2>/dev/null | grep -oP 'Candidate:\s*(?:[0-9]+:)?\K[0-9]+\.[0-9]+' | head -1 || true)
    version_to_num "$v"
}

# True if the apt candidate for $1 has a version number >= $2
apt_meets_min() { [ "$(apt_candidate_version_num "$1")" -ge "$2" ]; }

# True if $1 exists in the apt archive at all (any version). For tools we only
# want from the distro repos, with no source-build fallback.
apt_available() { [ "$(apt_candidate_version_num "$1")" -gt 0 ]; }

# Remove stale source-built copies of a binary so the apt copy wins on PATH.
# REQUIRED because .zshrc puts ~/.cargo/bin and ~/go/bin BEFORE /usr/bin and
# /usr/local/bin, so a leftover cargo/go binary would otherwise shadow the
# apt-installed one when this script is re-run over a previous install.
remove_source_builds() { rm -f "$HOME/go/bin/$1" "$HOME/.cargo/bin/$1" 2>/dev/null || true; }

# Install Go tool
# Usage: install_go_tool <tool-name> <go-package-path> [mode]
#   mode: "update" (default) rebuilds @latest every run.
#         "once" skips the build when <tool-name> is already on PATH - use for
#         discontinued/archived upstreams we want to freeze at the installed build
#         (also avoids pulling @latest from a dormant, hijackable namespace).
install_go_tool() {
    local tool_name="$1"
    local package_path="$2"
    local mode="${3:-update}"

    if command -v "$tool_name" &> /dev/null; then
        if [ "$mode" = "once" ]; then
            log "${tool_name} already installed - skipping update (install-once)"
            return 0
        fi
        log "Updating ${tool_name}..."
    else
        log "Installing ${tool_name}..."
    fi
    export PATH=$HOME/go/bin:$PATH
    export GOPROXY="https://proxy.golang.org,off"
    export GOSUMDB="sum.golang.org"
    # Non-fatal: a failed build (e.g. OOM on a low-RAM VM) is recorded and the run
    # continues instead of aborting ('||' keeps 'set -e' from firing at the call site).
    go install -v "$package_path" || note_build_failure "$tool_name"
}

# Install an apt package if not already present (idempotent, with logging).
# Usage: install_apt_package <display-name> <apt-package>
install_apt_package() {
    local display="$1"
    local apt_pkg="$2"
    if ! dpkg -s "$apt_pkg" &> /dev/null; then
        log "Installing ${display} from apt (${apt_pkg})..."
        apt_get install -y "$apt_pkg"
    else
        log "${display} already installed from apt (${apt_pkg})"
    fi
}

# Install a tool ONLY from the distro repos, with no source-build fallback; skip
# quietly on releases that don't package it. For tools we deliberately never
# compile (procs, dust). Usage: install_apt_only <display-name> <apt-package>
install_apt_only() {
    local display="$1"
    local apt_pkg="$2"
    if apt_available "$apt_pkg"; then
        install_apt_package "$display" "$apt_pkg"
    else
        log "${display} not in apt repositories on this release (${apt_pkg}) - skipping"
    fi
}

# Install the Microsoft package-signing keys (shared by the VS Code and PowerShell
# repos). Always rebuilt, never cached: Microsoft rotates signing keys
# (microsoft.asc signs pre-2025 repos like repos/code, microsoft-rolling.asc
# carries the current and future keys), so a stale keyring breaks apt-get update.
ensure_microsoft_keyring() {
    command -v gpg &> /dev/null || apt_get install -y gpg
    curl --proto '=https' --tlsv1.2 -fsSL \
        https://packages.microsoft.com/keys/microsoft.asc \
        https://packages.microsoft.com/keys/microsoft-rolling.asc | gpg --dearmor > /tmp/microsoft.gpg
    sudo install -m 644 /tmp/microsoft.gpg /usr/share/keyrings/microsoft.gpg
    rm -f /tmp/microsoft.gpg
}

# Write the Microsoft prod repo apt sources for the given release path/suite.
# Usage: write_microsoft_prod_sources <distro> <version_id> <suite>
write_microsoft_prod_sources() {
    sudo tee /etc/apt/sources.list.d/microsoft-prod.sources > /dev/null << EOF
Types: deb
URIs: https://packages.microsoft.com/$1/$2/prod
Suites: $3
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
}

# Write the Docker CE apt sources for the given distro/suite.
# Usage: write_docker_sources <distro> <codename>
write_docker_sources() {
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$1 $2 stable" |
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
}

# Install Go tool: prefer a recent-enough apt package, else build via 'go install'.
# Usage: install_go_tool_apt <bin> <apt-pkg> <min_num> <go-package-path> [apt_bin] [min_go]
#   apt_bin: the executable the apt package installs, if it differs from <bin>
#            (e.g. the 'yq-go' package installs 'yq-go'); a /usr/local/bin/<bin>
#            symlink is created so <bin> resolves to it.
#   min_go:  minimum get_go_version needed to build from source in the fallback.
install_go_tool_apt() {
    local bin="$1"
    local apt_pkg="$2"
    local min_num="$3"
    local go_pkg="$4"
    local apt_bin="${5:-$1}"
    local min_go="${6:-0}"

    if apt_meets_min "$apt_pkg" "$min_num"; then
        install_apt_package "$bin" "$apt_pkg"
        # Expose an apt binary under its expected name (e.g. yq -> yq-go).
        # /usr/local/bin precedes /usr/bin, so this also shadows any same-named
        # unrelated package (e.g. the Python 'yq').
        if [ "$apt_bin" != "$bin" ] && command -v "$apt_bin" &> /dev/null; then
            sudo ln -sf "$(command -v "$apt_bin")" "/usr/local/bin/${bin}"
        fi
        remove_source_builds "$bin"   # drop stale ~/go/bin copy so apt wins on PATH
    elif [ "$(get_go_version)" -ge "$min_go" ]; then
        install_go_tool "$bin" "$go_pkg"
    else
        warn "${bin}: no recent apt package and Go too old to build - skipping"
    fi
}

# Install Cargo tool: prefer a recent-enough apt package, else build via cargo.
# Usage: install_cargo_tool <binary-name> <apt-package> <cargo-crate> [min_num] [mode]
#   mode: "update" (default) or "once" (skip the cargo build when already installed;
#         for discontinued upstreams). Only affects the cargo fallback path.
install_cargo_tool() {
    local bin_name="$1"
    local apt_pkg="$2"
    local cargo_crate="$3"
    local min_num="${4:-0}"
    local mode="${5:-update}"

    if apt_meets_min "$apt_pkg" "$min_num"; then
        install_apt_package "$bin_name" "$apt_pkg"
        remove_source_builds "$bin_name"   # drop stale ~/.cargo/bin copy so apt wins on PATH
    elif command -v cargo &> /dev/null; then
        if command -v "$bin_name" &> /dev/null; then
            if [ "$mode" = "once" ]; then
                log "${bin_name} already installed - skipping update (install-once)"
                return 0
            fi
            log "Checking ${bin_name} for updates (cargo)..."
        else
            log "Installing ${bin_name} via cargo..."
        fi
        # Non-fatal (see install_go_tool): cargo builds are especially RAM-hungry.
        cargo install "$cargo_crate" --locked || note_build_failure "$bin_name"
    else
        warn "${bin_name}: apt package too old/absent and cargo unavailable - skipping"
    fi
}

# Install Rust via rustup
install_rust_via_rustup() {
    log "Installing Rust via rustup (official Rust installer)..."

    # Download and run rustup-init. RUSTUP_INIT_SKIP_PATH_CHECK silences the
    # "existing Rust at /usr/bin" warning when apt's rustc is also installed —
    # ~/.cargo/bin is prepended to PATH in .zshrc so rustup's toolchain wins.
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | RUSTUP_INIT_SKIP_PATH_CHECK=yes sh -s -- -y --default-toolchain stable

    # Source cargo environment for this script
    export CARGO_HOME="$HOME/.cargo"
    export RUSTUP_HOME="$HOME/.rustup"
    export PATH="$CARGO_HOME/bin:$PATH"

    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env" || true
    fi

    log "Rust installed successfully via rustup"
}

if ! is_kali_linux; then
    warn "This script is primarily designed for Kali Linux. Continuing anyway..."
fi

#############################################################################
# PHASE 0: Self-Update
#############################################################################

log "Checking for script updates..."

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if git rev-parse --git-dir > /dev/null 2>&1; then
    log "Git repository detected, checking for updates..."

    # Fetch latest changes
    git fetch origin 2>/dev/null || true

    # Count commits we don't have that remote has
    BEHIND=$(git rev-list --count HEAD..@{u} 2>/dev/null) || BEHIND=0

    if [ "$BEHIND" -gt 0 ]; then
        log "Updates found! Pulling latest changes..."
        git pull --ff-only
        log "Re-executing updated script..."
        exec "$0" "${ORIGINAL_ARGS[@]}" || error "Failed to re-execute updated script"
    else
        log "Script is up to date"
    fi
else
    warn "Not running from a git repository. Self-update disabled."
fi

# --harden-only: apply supply-chain hardening and exit (no installs)
if [[ "$HARDEN_ONLY" == "true" ]]; then
    log "Running in harden-only mode (no package installs, no shell changes)"
    apply_supply_chain_hardening
    log "Harden-only mode complete!"
    exit 0
fi

#############################################################################
# PHASE 1: System Setup
#############################################################################

log "Starting Linux setup..."

# Refresh the Microsoft signing keys if a previous run configured those repos -
# a key rotation on packages.microsoft.com would otherwise break the apt-get
# update below (and with it every re-run of this script).
if [ -f /etc/apt/sources.list.d/microsoft-prod.sources ] || [ -f /etc/apt/sources.list.d/vscode.sources ]; then
    log "Refreshing Microsoft repository signing keys..."
    ensure_microsoft_keyring
fi

# Update package lists and upgrade system
log "Updating package lists and upgrading system..."
apt_get update
apt_get dist-upgrade -y

# Install essential packages
log "Installing essential packages..."
apt_get install -y \
    ca-certificates \
    build-essential \
    curl \
    wget \
    unzip \
    git \
    fzf \
    tree \
    hstr \
    bubblewrap \
    ripgrep \
    fd-find \
    moreutils \
    unp \
    htop \
    tmux \
    ncdu \
    lsof \
    jq \
    bat \
    nano \
    exiftool \
    libpcap-dev \
    ufw \
    python3-dev \
    python3-pip \
    python3-venv \
    golang \
    zsh \
    zsh-autosuggestions \
    zsh-syntax-highlighting

# Install Rust - either from repo (if >= 1.85) or via rustup. Rust is always
# installed as a dev runtime; sd/delta still prefer apt when it ships a
# recent-enough build (see install_cargo_tool below) and only fall back to
# compiling via cargo.
log "Checking Rust version in repositories..."
REPO_RUST_VERSION=$(apt-cache policy rustc 2>/dev/null | grep -oP 'Candidate:\s*\K[0-9]+\.[0-9]+' | head -1 || true)
if [ -z "$REPO_RUST_VERSION" ]; then
    REPO_RUST_VERSION="0.0"
    warn "Could not determine repository Rust version"
fi
REPO_RUST_VERSION_NUM=$(version_to_num "$REPO_RUST_VERSION")
MINIMUM_RUST_VERSION=185  # Rust 1.85 minimum for modern tools

log "Repository has Rust version: $REPO_RUST_VERSION (numeric: $REPO_RUST_VERSION_NUM, minimum required: $MINIMUM_RUST_VERSION)"

if ! command -v cargo &> /dev/null && [ "$REPO_RUST_VERSION_NUM" -ge "$MINIMUM_RUST_VERSION" ]; then
    log "Installing Rust from repositories (version $REPO_RUST_VERSION)..."
    apt_get install -y cargo rustc
elif ! command -v cargo &> /dev/null; then
    log "Repository version $REPO_RUST_VERSION is below required $MINIMUM_RUST_VERSION, installing Rust via rustup..."
    install_rust_via_rustup
elif command -v rustup &> /dev/null; then
    log "Updating Rust via rustup..."
    rustup update stable
else
    INSTALLED_RUST_VERSION=$(rustc --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' | head -1 || true)
    INSTALLED_RUST_VERSION_NUM=$(version_to_num "$INSTALLED_RUST_VERSION")
    log "Installed Rust version: ${INSTALLED_RUST_VERSION:-unknown} (numeric: $INSTALLED_RUST_VERSION_NUM, minimum required: $MINIMUM_RUST_VERSION)"
    if [ "$INSTALLED_RUST_VERSION_NUM" -lt "$MINIMUM_RUST_VERSION" ]; then
        log "Installed Rust is below required $MINIMUM_RUST_VERSION, installing rustup for a newer toolchain..."
        install_rust_via_rustup
    else
        log "Rust is already installed (apt-managed, updated via dist-upgrade)"
    fi
fi

# Install Bun (JavaScript/TypeScript runtime, package manager, drop-in Node.js replacement)
log "Installing Bun..."
if ! command -v bun &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -fsSL https://bun.com/install | bash

    # Source bun environment for this script
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"

    log "Bun installed successfully"
else
    log "Updating Bun..."
    bun upgrade
fi

# Create node/npx shims pointing to bun for Node.js drop-in compatibility, but
# ONLY when the system has no real node/npx of its own. Bun only auto-symlinks
# node temporarily during `bun run` (in /tmp/bun-node/); these permanent shims
# make `node` and `npx` work system-wide for scripts, shebangs
# (#!/usr/bin/env node), and tools that invoke node/npx directly. Because
# ~/.bun/bin sits ahead of /usr/bin on PATH, an unconditional shim would shadow
# a genuine Node.js install (e.g. apt's /usr/bin/node) — so each shim is skipped
# (and any stale shim from a prior run removed) when a real tool already exists.
# Note: npm is NOT shimmed — bun's package manager uses its own CLI interface
# (bun install, bun add, etc.) and does not emulate npm's command set when
# invoked as "npm"; it therefore never shadows a system npm.
log "Setting up Node.js compatibility shims for Bun..."
BUN_BIN="${BUN_INSTALL:-$HOME/.bun}/bin"

# True if a real <tool> is resolvable on PATH *outside* Bun's own bin dir.
# $BUN_BIN is stripped first so a shim from a previous run can't mask a genuine
# system node/npx (keeps this block idempotent on re-runs).
node_tool_exists_outside_bun() {
    local tool="$1" p rest="" IFS=':'
    for p in $PATH; do
        [ "$p" = "$BUN_BIN" ] && continue
        rest="${rest:+$rest:}$p"
    done
    PATH="$rest" command -v "$tool" &> /dev/null
}

if [ -x "$BUN_BIN/bun" ]; then
    # node
    if node_tool_exists_outside_bun node; then
        # A real node is installed elsewhere on PATH — don't shadow it, and drop
        # any node shim we created on an earlier run (only ours: a symlink here).
        [ -L "$BUN_BIN/node" ] && rm -f "$BUN_BIN/node"
        log "System 'node' already installed; leaving it in place (no Bun shim)"
    else
        ln -sf "$BUN_BIN/bun" "$BUN_BIN/node"
        log "Created node -> bun shim in $BUN_BIN"
    fi

    # npx
    if node_tool_exists_outside_bun npx; then
        # A real npx is installed elsewhere on PATH — don't shadow it, and drop
        # any npx wrapper we created on an earlier run (rm -f no-ops if absent).
        rm -f "$BUN_BIN/npx"
        log "System 'npx' already installed; leaving it in place (no Bun shim)"
    else
        # npx is a wrapper, not a symlink: bun's argv[0] sniffing only recognises
        # "bunx"/"node", so a symlink invoked as "npx" runs `bun <arg>` and fails
        # with `Script not found`. The wrapper calls `bun x` explicitly.
        # Write via cat+chmod rather than `install /dev/stdin`. On the reporter's
        # Ubuntu 26.04 (uutils/Rust coreutils, the new default) uutils `install`
        # couldn't read the /dev/stdin heredoc source -> bare "install: No such
        # file or directory". uutils 0.8.0 handles this in a normal env, so the
        # trigger is env-specific (/dev/stdin not resolvable), but cat>+chmod never
        # touches /dev/stdin and is robust on GNU and uutils alike. rm -f first so a
        # pre-existing symlink from an older run is replaced, not followed.
        rm -f "$BUN_BIN/npx"
        cat > "$BUN_BIN/npx" << NPX_EOF
#!/bin/sh
exec "$BUN_BIN/bun" x "\$@"
NPX_EOF
        chmod 755 "$BUN_BIN/npx"
        log "Created npx -> 'bun x' wrapper in $BUN_BIN"
    fi
else
    warn "Bun binary not found at $BUN_BIN/bun, skipping Node.js compatibility shims"
fi

#############################################################################
# Package Manager Supply-Chain Hardening
#############################################################################

apply_supply_chain_hardening

# Install GUI applications if desktop environment is available
if has_desktop_environment; then
    log "Desktop environment detected - installing GUI applications"
    apt_get install -y \
        gedit \
        gedit-plugins \
        fonts-firacode \
        terminator \
        meld \
        xsel
        
    # Configure GTK terminal padding
    log "Configuring GTK terminal padding..."
    mkdir -p ~/.config/gtk-3.0
    write_config_file ~/.config/gtk-3.0/gtk.css << 'EOF'
VteTerminal, TerminalScreen, vte-terminal {
    padding: 8px 8px 8px 8px; /* Top Right Bottom Left */
    -VteTerminal-inner-border: 8px 8px 8px 8px; /* Older versions might need this */
}
EOF
else
    log "No desktop environment detected - skipping GUI applications"
fi

# Install Kali-specific package - only install on Kali Linux
if is_kali_linux && [ "$NO_HACKING_TOOLS" != true ]; then
    log "Installing hacking tools..."
    apt_get install -y massdns mitmproxy || true
else
    warn "Skipping hacking tools installation"
fi

# Install pipx (Python application installer)
log "Installing pipx..."
if ! command -v pipx &> /dev/null; then
    #python3 -m pip install --user pipx
    apt_get install -y pipx
else
    log "pipx is already installed"
fi

# Install uv (modern Python package installer)
log "Installing uv..."
export PATH=$HOME/.local/bin:$PATH
if ! command -v uv &> /dev/null; then
    pipx install uv
else
    log "Updating uv..."
    pipx upgrade uv 2>/dev/null || pipx install --force uv
fi

# Install Python tools with uv
log "Installing Python tools with uv..."
if command -v uv &> /dev/null; then
    uv tool install --force httpie
    uv tool install --force name-that-hash
    uv tool install --force tldr
else
    warn "uv not available, skipping Python tools installation"
fi

# Install Docker CE
log "Installing Docker CE..."
if ! command -v docker &> /dev/null; then
    # Remove conflicting packages
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do apt_get remove -y "$pkg" || true; done

    # Select the Docker repo: Ubuntu uses Docker's ubuntu repo; everything
    # else Debian-based (Debian, Kali, derivatives) uses the debian repo.
    . /etc/os-release
    if is_ubuntu; then
        DOCKER_DISTRO="ubuntu"
        DOCKER_CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
        DOCKER_FALLBACK="noble"
    else
        DOCKER_DISTRO="debian"
        DOCKER_CODENAME="${VERSION_CODENAME:-}"
        DOCKER_FALLBACK="trixie"
    fi

    # Capability probe: Docker only publishes dists for releases it supports.
    # Fall back to the newest supported LTS/stable suite when absent. Skip the
    # probe where the answer is statically known (kali-rolling is never
    # published; sid has no VERSION_CODENAME).
    if [ -z "$DOCKER_CODENAME" ] || [ "$DOCKER_CODENAME" = "kali-rolling" ] || \
       ! repo_suite_published "https://download.docker.com/linux/${DOCKER_DISTRO}" "$DOCKER_CODENAME"; then
        log "No Docker repo for ${DOCKER_DISTRO}/${DOCKER_CODENAME:-unknown} - falling back to ${DOCKER_FALLBACK}"
        DOCKER_CODENAME="$DOCKER_FALLBACK"
    fi

    log "Using Docker repository: $DOCKER_DISTRO/$DOCKER_CODENAME"

    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl --proto '=https' --tlsv1.2 -fsSL https://download.docker.com/linux/$DOCKER_DISTRO/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources
    write_docker_sources "$DOCKER_DISTRO" "$DOCKER_CODENAME"
    apt_get update

    # A new release's dist can exist while its stable channel is still empty
    # (Ubuntu 24.04 shipped this way at launch), so verify a docker-ce
    # candidate actually appeared - otherwise fall back and re-update.
    if [ "$(apt_candidate_version_num docker-ce)" -eq 0 ] && [ "$DOCKER_CODENAME" != "$DOCKER_FALLBACK" ]; then
        warn "Docker repo for ${DOCKER_DISTRO}/${DOCKER_CODENAME} has no docker-ce package - falling back to ${DOCKER_FALLBACK}"
        DOCKER_CODENAME="$DOCKER_FALLBACK"
        write_docker_sources "$DOCKER_DISTRO" "$DOCKER_CODENAME"
        apt_get update
    fi

    # Install Docker CE and components
    apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Enable and start Docker service
    sudo systemctl enable docker || true
    sudo systemctl start docker || true

    log "Docker CE installed and started successfully"
else
    log "Docker is already installed"
fi

# Configure Docker group and permissions (Kali only: docker group membership
# is root-equivalent, so on other distros it stays opt-in via sudo)
if is_kali_linux; then
    log "Configuring Docker group and permissions..."
    sudo groupadd docker 2>/dev/null || true
    sudo usermod -aG docker "$USER"
    if [[ -d "$HOME/.docker" ]]; then
        sudo chown "$USER":"$USER" "$HOME/.docker" -R
        sudo chmod g+rwx "$HOME/.docker" -R
    fi
    log "Docker group configured. You'll need to log out and back in for group changes to take effect."
else
    log "Skipping docker group membership (root-equivalent; add yourself manually with: sudo usermod -aG docker \$USER)"
fi

# Install Visual Studio Code
if has_desktop_environment; then
    log "Installing Visual Studio Code..."
    if ! command -v code &> /dev/null; then
        ensure_microsoft_keyring

        # Create VSCode sources file
        sudo tee /etc/apt/sources.list.d/vscode.sources > /dev/null << 'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
        
        apt_get install -y apt-transport-https
        apt_get update
        apt_get install -y code
    else
        log "Visual Studio Code is already installed"
    fi
else
    log "No desktop environment detected - skipping Visual Studio Code installation"
fi

# Install PowerShell (pwsh): prefer the distro's native package (Kali ships one),
# add Microsoft's prod repo only when apt has no usable candidate.
log "Installing PowerShell..."
if ! command -v pwsh &> /dev/null; then
    if apt_meets_min powershell "$PWSH_MIN"; then
        # Native repo (Kali) or Microsoft repo already configured
        install_apt_package "PowerShell" "powershell"
    else
        # Determine the Microsoft repo path for this distro, and the newest
        # Microsoft-supported release to fall back to.
        . /etc/os-release
        if is_ubuntu; then
            PWSH_DISTRO="ubuntu"
            PWSH_SUITE="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
            PWSH_FALLBACK_VERSION_ID="24.04"
            PWSH_FALLBACK_SUITE="noble"
        else
            PWSH_DISTRO="debian"
            PWSH_SUITE="$VERSION_CODENAME"
            PWSH_FALLBACK_VERSION_ID="12"
            PWSH_FALLBACK_SUITE="bookworm"
        fi
        PWSH_VERSION_ID="$VERSION_ID"

        # Capability probe: Microsoft only publishes the repo for supported
        # releases. Fall back to the newest supported one when absent
        # (the powershell deb is a universal package, so this is safe).
        if ! repo_suite_published "https://packages.microsoft.com/${PWSH_DISTRO}/${PWSH_VERSION_ID}/prod" "$PWSH_SUITE"; then
            warn "No Microsoft repo for ${PWSH_DISTRO}/${PWSH_VERSION_ID} - falling back to ${PWSH_DISTRO} ${PWSH_FALLBACK_VERSION_ID} (${PWSH_FALLBACK_SUITE})"
            PWSH_VERSION_ID="$PWSH_FALLBACK_VERSION_ID"
            PWSH_SUITE="$PWSH_FALLBACK_SUITE"
        fi

        ensure_microsoft_keyring
        write_microsoft_prod_sources "$PWSH_DISTRO" "$PWSH_VERSION_ID" "$PWSH_SUITE"
        apt_get update

        # A brand-new release's repo can exist before the powershell package
        # is published to it (e.g. Ubuntu 26.04 at launch: the resolute repo
        # answers, but carries no powershell). Verify a candidate actually
        # appeared - otherwise fall back and re-update.
        if ! apt_meets_min powershell "$PWSH_MIN" && [ "$PWSH_SUITE" != "$PWSH_FALLBACK_SUITE" ]; then
            warn "Microsoft repo for ${PWSH_DISTRO}/${PWSH_VERSION_ID} has no powershell package - falling back to ${PWSH_DISTRO} ${PWSH_FALLBACK_VERSION_ID} (${PWSH_FALLBACK_SUITE})"
            PWSH_VERSION_ID="$PWSH_FALLBACK_VERSION_ID"
            PWSH_SUITE="$PWSH_FALLBACK_SUITE"
            write_microsoft_prod_sources "$PWSH_DISTRO" "$PWSH_VERSION_ID" "$PWSH_SUITE"
            apt_get update
        fi
        install_apt_package "PowerShell" "powershell"
    fi
else
    log "PowerShell is already installed"
fi

# Disable screensaver and power management
if has_desktop_environment; then
    log "Disabling screensaver and power save options..."
    if command -v xfconf-query &> /dev/null; then
        # Disable screensaver and lock screen (create setting if it doesn't exist)
        xfconf-query -c xfce4-screensaver -p /saver/enabled --create -t bool -s false || true
        xfconf-query -c xfce4-screensaver -p /lock/enabled --create -t bool -s false || true

        # Disable Display Power Management entirely
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled --create -t bool -s false || true
    else
        warn "xfconf-query not available, skipping power management configuration"
    fi
else
    log "No desktop environment detected - skipping screensaver configuration"
fi

# Set Terminator as default terminal
if has_desktop_environment; then
    log "Setting Terminator as default terminal..."
    mkdir -p ~/.config/xfce4
    write_config_file ~/.config/xfce4/helpers.rc << 'EOF'
TerminalEmulator=terminator
EOF
else
    log "No desktop environment detected - skipping terminal configuration"
fi

# Configure .zshenv for Ubuntu systems to skip global compinit
if is_ubuntu; then
    log "Configuring .zshenv for Ubuntu (skip global compinit for faster startup)..."

    if [ -f ~/.zshenv ] && grep -q 'skip_global_compinit=1' ~/.zshenv; then
        log ".zshenv already has skip_global_compinit setting"
    else
        cat >> ~/.zshenv << 'EOF'

# Skip Ubuntu's global compinit for faster zsh startup
# Ubuntu sources /etc/zsh/zshrc which runs compinit, but we handle
# completion initialization more efficiently in ~/.zshrc with caching
skip_global_compinit=1
EOF
        log ".zshenv configured successfully"
    fi
else
    log "Not Ubuntu - skipping .zshenv configuration"
fi

# Configure zsh with Kali Linux default baseline plus enhancements
log "Configuring zsh..."

# Check if .zshrc exists and prompt for overwrite
OVERWRITE_ZSHRC=true
if [ -f ~/.zshrc ]; then
    if prompt_yes_no "Overwrite existing .zshrc (strongly recommended on first run!)?" "Y"; then
        backup_file ~/.zshrc
    else
        OVERWRITE_ZSHRC=false
        log "Keeping existing .zshrc"
    fi
fi

if [ "$OVERWRITE_ZSHRC" = true ]; then
cat > ~/.zshrc << 'EOF'
# Default ~/.zshrc from Kali Linux
# ~/.zshrc file for zsh interactive shells.
# see /usr/share/doc/zsh/examples/zshrc for examples

# Keep $PATH (and the tied $path array) free of duplicate entries, so
# re-sourcing this file or nested shells cannot bloat $PATH over time.
typeset -U path PATH

setopt autocd              # change directory just by typing its name
#setopt correct            # auto correct mistakes
setopt interactivecomments # allow comments in interactive mode
setopt magicequalsubst     # enable filename expansion for arguments of the form ‘anything=expression’
setopt nonomatch           # hide error message if there is no match for the pattern
setopt notify              # report the status of background jobs immediately
setopt numericglobsort     # sort filenames numerically when it makes sense
setopt promptsubst         # enable command substitution in prompt

WORDCHARS='_-' # Don't consider certain characters part of the word

# hide EOL sign ('%')
PROMPT_EOL_MARK=""

# configure key keybindings
bindkey -e                                        # emacs key bindings
bindkey ' ' magic-space                           # do history expansion on space
bindkey '^U' backward-kill-line                   # ctrl + U
bindkey '^[[3;5~' kill-word                       # ctrl + Supr
bindkey '^[[3~' delete-char                       # delete
bindkey '^[[1;5C' forward-word                    # ctrl + ->
bindkey '^[[1;5D' backward-word                   # ctrl + <-
bindkey '^[[5~' beginning-of-buffer-or-history    # page up
bindkey '^[[6~' end-of-buffer-or-history          # page down
bindkey '^[[H' beginning-of-line                  # home
bindkey '^[[F' end-of-line                        # end
bindkey '^[[Z' undo                               # shift + tab undo last action

# enable completion features
autoload -Uz compinit
# Only update completion cache once a day to speed up zsh start
zcompdump_file="${XDG_CACHE_HOME:-$HOME/.cache}/zcompdump"
setopt extended_glob
# Check if cache is fresh (less than 20 hours old)
if [[ -n $zcompdump_file(#qNmh-20) ]]; then
  # Cache exists and is fresh - use it without checks
  compinit -C -d "$zcompdump_file"
else
  # Cache is stale or doesn't exist - regenerate
  mkdir -p "${zcompdump_file%/*}"
  compinit -i -d "$zcompdump_file"
  touch "$zcompdump_file"
  # Pre-parse the dump to wordcode. compinit -C's internal `source` auto-loads
  # the faster .zwc when it is newer than the text dump (~12ms/startup saved on
  # a typical dump). Guarded so a write failure falls back to the text dump.
  zcompile "$zcompdump_file" 2>/dev/null || true
fi
unsetopt extended_glob
unset zcompdump_file
zstyle ':completion:*:*:*:*:*' menu select
zstyle ':completion:*' auto-description 'specify: %d'
zstyle ':completion:*' completer _expand _complete
zstyle ':completion:*' format 'Completing %d'
zstyle ':completion:*' group-name ''
zstyle ':completion:*' list-colors ''
zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' rehash true
zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
zstyle ':completion:*' use-compctl false
zstyle ':completion:*' verbose true
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'

# History configurations
HISTFILE=~/.zsh_history
HISTSIZE=1000
SAVEHIST=2000
setopt hist_expire_dups_first # delete duplicates first when HISTFILE size exceeds HISTSIZE
setopt hist_ignore_dups       # ignore duplicated commands history list
setopt hist_ignore_space      # ignore commands that start with space
setopt hist_verify            # show command with history expansion to user before running it
#setopt share_history         # share command history data

# force zsh to show the complete history
alias history="history 0"

# configure `time` format
TIMEFMT=$'\nreal\t%E\nuser\t%U\nsys\t%S\ncpu\t%P'

# make less more friendly for non-text input files, see lesspipe(1)
#[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

# uncomment for a colored prompt, if the terminal has the capability; turned
# off by default to not distract the user: the focus in a terminal window
# should be on the output of commands, not on the prompt
force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
        # We have color support; assume it's compliant with Ecma-48
        # (ISO/IEC-6429). (Lack of such support is extremely rare, and such
        # a case would tend to support setf rather than setaf.)
        color_prompt=yes
    else
        color_prompt=
    fi
fi

configure_prompt() {
    prompt_symbol=@
    # Skull emoji for root terminal
    #[ "$EUID" -eq 0 ] && prompt_symbol=💀
    case "$PROMPT_ALTERNATIVE" in
        twoline)
            PROMPT=$'%F{%(#.blue.green)}┌──${debian_chroot:+($debian_chroot)─}${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV))─}(%B%F{%(#.red.blue)}%n'$prompt_symbol$'%m%b%F{%(#.blue.green)})-[%B%F{reset}%(6~.%-1~/…/%4~.%5~)%b%F{%(#.blue.green)}]\n└─%B%(#.%F{red}#.%F{blue}$)%b%F{reset} '
            # Right-side prompt with exit codes and background processes
            #RPROMPT=$'%(?.. %? %F{red}%B⨯%b%F{reset})%(1j. %j %F{yellow}%B⚙%b%F{reset}.)'
            ;;
        oneline)
            PROMPT=$'${debian_chroot:+($debian_chroot)}${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV))}%B%F{%(#.red.blue)}%n@%m%b%F{reset}:%B%F{%(#.blue.green)}%~%b%F{reset}%(#.#.$) '
            RPROMPT=
            ;;
        backtrack)
            PROMPT=$'${debian_chroot:+($debian_chroot)}${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV))}%B%F{red}%n@%m%b%F{reset}:%B%F{blue}%~%b%F{reset}%(#.#.$) '
            RPROMPT=
            ;;
    esac
    unset prompt_symbol
}

# The following block is surrounded by two delimiters.
# These delimiters must not be modified. Thanks.
# START KALI CONFIG VARIABLES
PROMPT_ALTERNATIVE=twoline
NEWLINE_BEFORE_PROMPT=yes
# STOP KALI CONFIG VARIABLES

if [ "$color_prompt" = yes ]; then
    # override default virtualenv indicator in prompt
    VIRTUAL_ENV_DISABLE_PROMPT=1

    configure_prompt

    # enable auto-suggestions based on the history
    if [ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
        # Pre-config (MUST be set BEFORE sourcing)
        ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE='50'
        ZSH_AUTOSUGGEST_USE_ASYNC=1
        ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=240'
        . /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
        # Add custom widgets to clear list AFTER sourcing (to preserve defaults like accept-line)
        ZSH_AUTOSUGGEST_CLEAR_WIDGETS+=(
            history-beginning-search-backward-end
            history-beginning-search-forward-end
            history-beginning-search-backward
            history-beginning-search-forward
        )
    fi

    # enable syntax-highlighting (MUST be loaded after autosuggestions)
    if [ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
        . /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
        ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern)
        ZSH_HIGHLIGHT_STYLES[default]=none
        ZSH_HIGHLIGHT_STYLES[unknown-token]=underline
        ZSH_HIGHLIGHT_STYLES[reserved-word]=fg=cyan,bold
        ZSH_HIGHLIGHT_STYLES[suffix-alias]=fg=green,underline
        ZSH_HIGHLIGHT_STYLES[global-alias]=fg=green,bold
        ZSH_HIGHLIGHT_STYLES[precommand]=fg=green,underline
        ZSH_HIGHLIGHT_STYLES[commandseparator]=fg=blue,bold
        ZSH_HIGHLIGHT_STYLES[autodirectory]=fg=green,underline
        ZSH_HIGHLIGHT_STYLES[path]=bold
        ZSH_HIGHLIGHT_STYLES[path_pathseparator]=
        ZSH_HIGHLIGHT_STYLES[path_prefix_pathseparator]=
        ZSH_HIGHLIGHT_STYLES[globbing]=fg=blue,bold
        ZSH_HIGHLIGHT_STYLES[history-expansion]=fg=blue,bold
        ZSH_HIGHLIGHT_STYLES[command-substitution]=none
        ZSH_HIGHLIGHT_STYLES[command-substitution-delimiter]=fg=magenta,bold
        ZSH_HIGHLIGHT_STYLES[process-substitution]=none
        ZSH_HIGHLIGHT_STYLES[process-substitution-delimiter]=fg=magenta,bold
        ZSH_HIGHLIGHT_STYLES[single-hyphen-option]=fg=green
        ZSH_HIGHLIGHT_STYLES[double-hyphen-option]=fg=green
        ZSH_HIGHLIGHT_STYLES[back-quoted-argument]=none
        ZSH_HIGHLIGHT_STYLES[back-quoted-argument-delimiter]=fg=blue,bold
        ZSH_HIGHLIGHT_STYLES[single-quoted-argument]=fg=yellow
        ZSH_HIGHLIGHT_STYLES[double-quoted-argument]=fg=yellow
        ZSH_HIGHLIGHT_STYLES[dollar-quoted-argument]=fg=yellow
        ZSH_HIGHLIGHT_STYLES[rc-quote]=fg=magenta
        ZSH_HIGHLIGHT_STYLES[dollar-double-quoted-argument]=fg=magenta,bold
        ZSH_HIGHLIGHT_STYLES[back-double-quoted-argument]=fg=magenta,bold
        ZSH_HIGHLIGHT_STYLES[back-dollar-quoted-argument]=fg=magenta,bold
        ZSH_HIGHLIGHT_STYLES[assign]=none
        ZSH_HIGHLIGHT_STYLES[redirection]=fg=blue,bold
        ZSH_HIGHLIGHT_STYLES[comment]=fg=black,bold
        ZSH_HIGHLIGHT_STYLES[named-fd]=none
        ZSH_HIGHLIGHT_STYLES[numeric-fd]=none
        ZSH_HIGHLIGHT_STYLES[arg0]=fg=cyan
        ZSH_HIGHLIGHT_STYLES[bracket-error]=fg=red,bold
        ZSH_HIGHLIGHT_STYLES[bracket-level-1]=fg=blue,bold
        ZSH_HIGHLIGHT_STYLES[bracket-level-2]=fg=green,bold
        ZSH_HIGHLIGHT_STYLES[bracket-level-3]=fg=magenta,bold
        ZSH_HIGHLIGHT_STYLES[bracket-level-4]=fg=yellow,bold
        ZSH_HIGHLIGHT_STYLES[bracket-level-5]=fg=cyan,bold
        ZSH_HIGHLIGHT_STYLES[cursor-matchingbracket]=standout
    fi
else
    PROMPT='${debian_chroot:+($debian_chroot)}%n@%m:%~%(#.#.$) '
fi
unset color_prompt force_color_prompt

toggle_oneline_prompt(){
    if [ "$PROMPT_ALTERNATIVE" = oneline ]; then
        PROMPT_ALTERNATIVE=twoline
    else
        PROMPT_ALTERNATIVE=oneline
    fi
    configure_prompt
    zle reset-prompt
}
zle -N toggle_oneline_prompt
# (Kali's default binds ^P to toggle_oneline_prompt here; the binding is
# removed in favour of zle-upify below - the widget stays for rebinding)

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*|Eterm|aterm|kterm|gnome*|alacritty)
    TERM_TITLE=$'\e]0;${debian_chroot:+($debian_chroot)}${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV))}%n@%m: %~\a'
    ;;
*)
    ;;
esac

precmd() {
    # Print the previously configured title
    print -Pnr -- "$TERM_TITLE"

    # Print a new line before the prompt, but only if it is not the first line
    if [ "$NEWLINE_BEFORE_PROMPT" = yes ]; then
        if [ -z "$_NEW_LINE_BEFORE_PROMPT" ]; then
            _NEW_LINE_BEFORE_PROMPT=1
        else
            print ""
        fi
    fi
}

# enable color support of ls, less and man, and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    # Cache dircolors output (like zoxide) to avoid forking dircolors on every
    # startup. Regenerate when the dircolors binary or a custom ~/.dircolors is
    # newer than the cache; $commands[dircolors] is a fork-free path lookup.
    _dircolors_cache="${XDG_CACHE_HOME:-$HOME/.cache}/dircolors.zsh"
    if [[ ! -s "$_dircolors_cache" || $commands[dircolors] -nt "$_dircolors_cache" || ( -r ~/.dircolors && ~/.dircolors -nt "$_dircolors_cache" ) ]]; then
        mkdir -p "${_dircolors_cache%/*}"
        if [[ -r ~/.dircolors ]]; then
            dircolors -b ~/.dircolors
        else
            dircolors -b
        fi > "$_dircolors_cache"
    fi
    source "$_dircolors_cache"
    unset _dircolors_cache
    export LS_COLORS="$LS_COLORS:ow=30;44:" # fix ls color for folders with 777 permissions

    alias ls='ls --color=auto'
    #alias dir='dir --color=auto'
    #alias vdir='vdir --color=auto'

    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
    alias diff='diff --color=auto'
    alias ip='ip --color=auto'

    export LESS_TERMCAP_mb=$'\E[1;31m'     # begin blink
    export LESS_TERMCAP_md=$'\E[1;36m'     # begin bold
    export LESS_TERMCAP_me=$'\E[0m'        # reset bold/blink
    export LESS_TERMCAP_so=$'\E[01;33m'    # begin reverse video
    export LESS_TERMCAP_se=$'\E[0m'        # reset reverse video
    export LESS_TERMCAP_us=$'\E[1;32m'     # begin underline
    export LESS_TERMCAP_ue=$'\E[0m'        # reset underline
    export MANROFFOPT="-c"                 # groff 1.23+: use classic output for LESS_TERMCAP

    # Take advantage of $LS_COLORS for completion as well
    zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
    zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
fi

# some more ls aliases
alias ll='ls -l'
alias la='ls -A'
alias l='ls -CF'

# enable command-not-found if installed
if [ -f /etc/zsh_command_not_found ]; then
    . /etc/zsh_command_not_found
fi

# ==========================================
# Linux Setup Script Custom Enhancements
# ==========================================

# Enhanced tab completion
setopt complete_in_word       # cd /ho/ka/Dow<TAB> expands to /home/kali/Downloads

# zoxide - smarter cd command (interactive shells only, to avoid interfering with automation).
# Cache the init script so we don't spawn `zoxide init` on every startup; $commands[zoxide] is
# zsh's fork-free path lookup, so regenerate only when the binary is newer (e.g. after upgrade).
if (( $+commands[zoxide] )) && [[ -o interactive ]]; then
    _zoxide_cache="${XDG_CACHE_HOME:-$HOME/.cache}/zoxide-init.zsh"
    if [[ ! -s "$_zoxide_cache" || $commands[zoxide] -nt "$_zoxide_cache" ]]; then
        mkdir -p "${_zoxide_cache%/*}"
        zoxide init zsh --cmd cd > "$_zoxide_cache"
    fi
    source "$_zoxide_cache"
    unset _zoxide_cache
fi

# fzf - fuzzy finder key bindings + completion (interactive shells only).
# Ctrl-T inserts file paths, Alt-C cds into a subdir, **<Tab> triggers fuzzy
# completion. Ctrl-R is left to the hstr block below (it runs after this one and
# rebinds Ctrl-R when hstr is present); without hstr, fzf's own Ctrl-R stays.
# Init output is cached like zoxide's so we don't fork fzf on every startup;
# $commands[fzf] is the fork-free path lookup, so regenerate only after upgrade.
if (( $+commands[fzf] )) && [[ -o interactive ]]; then
    if (( $+commands[fdfind] )); then
        export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --strip-cwd-prefix --exclude .git'
        export FZF_ALT_C_COMMAND='fdfind --type d --hidden --strip-cwd-prefix --exclude .git'
    fi
    export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'
    (( $+commands[batcat] )) && export FZF_CTRL_T_OPTS='--preview "batcat --color=always --line-range :200 {}"'
    export FZF_ALT_C_OPTS='--preview "tree -C {} 2>/dev/null | head -200"'

    _fzf_cache="${XDG_CACHE_HOME:-$HOME/.cache}/fzf-init.zsh"
    if [[ ! -s "$_fzf_cache" || $commands[fzf] -nt "$_fzf_cache" ]]; then
        mkdir -p "${_fzf_cache%/*}"
        # fzf >= 0.48 embeds the scripts (fzf --zsh); older Debian/Kali packages
        # ship them under /usr/share/doc instead. The '>' truncates the cache to
        # empty first, so a total failure degrades to no key bindings, not an error.
        fzf --zsh > "$_fzf_cache" 2>/dev/null \
            || cp /usr/share/doc/fzf/examples/key-bindings.zsh "$_fzf_cache" 2>/dev/null
    fi
    source "$_fzf_cache"
    unset _fzf_cache
    # Terminator grabs Ctrl-T for new-tab, so also bind the fzf file widget to
    # Alt-T (works inside Terminator and out). Guarded on the widget existing, in
    # case an old fzf shipped no --zsh integration and the cache is empty.
    (( ${+widgets[fzf-file-widget]} )) && bindkey '^[t' fzf-file-widget
fi

# Enhanced history settings
HISTSIZE=999999999
SAVEHIST=$HISTSIZE
setopt share_history          # share command history data
setopt hist_find_no_dups
setopt hist_reduce_blanks
#setopt hist_ignore_all_dups   # as the name says, beware!

# Better history incremental search
# Keys: up; down (both normal '^[[' and application-mode '^[O' sequences)
autoload -Uz history-search-end
zle -N history-beginning-search-backward-end history-search-end
zle -N history-beginning-search-forward-end  history-search-end
bindkey '^[OA' history-beginning-search-backward-end
bindkey '^[[A' history-beginning-search-backward-end
bindkey '^[OB' history-beginning-search-forward-end
bindkey '^[[B' history-beginning-search-forward-end
zle -A {.,}history-incremental-search-forward
zle -A {.,}history-incremental-search-backward

# Remove trailing newlines if any from pasted text (fork-free, and unlike
# echo it can't misparse a paste that happens to look like echo flags)
bracketed-paste() {
  emulate -L zsh -o extendedglob
  zle .$WIDGET && LBUFFER=${LBUFFER%%$'\n'#}
}
zle -N bracketed-paste

# HSTR configuration (guarded so ^R keeps stock incremental search on machines
# without hstr; the hist_ignore_space it wants is already set in the baseline)
if (( $+commands[hstr] )); then
    alias h=hstr                     # h to be alias for hstr
    export HSTR_CONFIG=hicolor,raw-history-view      # get more colors
    hstr_no_tiocsti() {
        local MERGE HSTR_OUT
        {
        MERGE="hstr ${BUFFER};"
        HSTR_OUT=$({ </dev/tty eval " $MERGE" } 2>&1 1>&3 3>&- );
        } 3>&1;
        BUFFER="${HSTR_OUT}"
        CURSOR=${#BUFFER}
        zle reset-prompt
    }
    zle -N hstr_no_tiocsti
    bindkey '\C-r' hstr_no_tiocsti
    export HSTR_TIOCSTI=n
fi

# https://github.com/akavel/up/ https://github.com/akavel/up/issues/44
# Guarded (like batcat below) so a copied .zshrc degrades gracefully when the
# bwrap sandbox or the frozen /usr/local/bin/up build is absent: ^P then keeps
# its stock zle binding instead of running a broken widget.
if (( $+commands[bwrap] )) && [[ -x /usr/local/bin/up ]]; then
    UPCOMMAND="bwrap --die-with-parent --ro-bind / / --bind /tmp /tmp --dev /dev --proc /proc --tmpfs /var --tmpfs /run --dir /run/user/$UID --unshare-pid --unshare-cgroup --unshare-ipc --unshare-net --cap-drop ALL /usr/local/bin/up"
    zle-upify() {
        local args="" buf tmp cmd

        if [[ -n "$ZSH_UP_UNSAFE_FULL_THROTTLE" ]]; then
            args="--unsafe-full-throttle"
        fi

        # Trim the whitespace and the last pipe character
        buf="$(echo -n "$BUFFER" | sed 's/[ |]*$//')"

        # Run up and save the output to a temporary file
        tmp="$(mktemp)"
        eval "$buf |& $UPCOMMAND $args -o '$tmp' 2>/dev/null"

        # Remove the first shebang line, and trailing newlines
        cmd="$(tail -n +2 "$tmp" | tr -d "\n")"
        rm -f "$tmp"

        # Set the current line if necessary
        if [[ -n "$cmd" ]]; then
            BUFFER="$buf | $cmd"
            zle end-of-line
        fi
    }
    zle -N zle-upify
    bindkey "${ZSH_UP_KEYBINDING:-^P}" zle-upify

    alias up="$UPCOMMAND"
fi
(( $+commands[bwrap] )) && alias polster='bwrap --die-with-parent --tmpfs /tmp --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 --ro-bind /sbin /sbin --ro-bind /etc /etc --dev /dev --proc /proc --tmpfs /var --tmpfs /run --dir /run/user/$UID --tmpfs /usr/share --unshare-all --clearenv'

alias upgrade-all='sudo apt-get -o DPkg::Lock::Timeout=300 update && sudo apt-get -o DPkg::Lock::Timeout=300 dist-upgrade; pipx upgrade-all'

# Git shortcuts. git is a hard dependency of this setup (self-update + delta
# config assume it), so these stay unguarded like upgrade-all/ll. 'g' is the
# standard git prefix (g status, g push, ...); 'gl' is the ADOG log
# (all/decorate/oneline/graph). No --color flag: git auto-colors to a TTY and
# stays plain when piped, so `gl | grep foo` won't get ANSI escapes injected.
alias g='git'
alias gl='git log --all --decorate --oneline --graph'

# Debian installs fd as 'fdfind'; guarded so the alias can't shadow a real fd
# binary (and pbcopy/pbpaste stay absent, not broken) on machines without them
(( $+commands[fdfind] )) && alias fd='fdfind'
if (( $+commands[xsel] )); then
    alias pbcopy='xsel --clipboard --input'
    alias pbpaste='xsel --clipboard --output'
fi

# bat: one theme for the aliases and MANPAGER below; guarded so cat/man keep
# their stock behavior on machines without batcat (e.g. dotfiles copied to a VM)
if (( $+commands[batcat] )); then
    export BAT_THEME=Coldark-Cold
    alias bat='batcat'
    alias cat='batcat --paging=never'

    # col -bx strips the overstrikes groff emits under MANROFFOPT="-c"
    # (set above) so batcat gets plain text to highlight.
    export MANPAGER="sh -c 'col -bx | batcat -l man -p'"
fi

# Trailing space lets zsh expand aliases after sudo (e.g., sudo ll -> sudo ls -l)
alias sudo='sudo '
alias sudp='sudo '  # deliberate typo guard

# Directory creation helpers
mkcd() {
  mkdir -p -- "$1" &&
  \cd -- "$1"
}

tempe() {
  local tmpdir="$(mktemp -d)"  # mktemp -d already creates the dir mode 0700
  \cd "$tmpdir"
  if [[ $# -eq 1 ]]; then
    \mkdir -p -- "$1"
    \cd -- "$1"
    chmod -R 0700 .
  fi
}

# Default editor
export EDITOR=nano
export VISUAL=nano

# Go PATH configuration
export PATH=$HOME/go/bin:$PATH

# Rust/Cargo PATH configuration
export PATH=$HOME/.cargo/bin:$PATH

# Bun PATH configuration
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Python uv and local packages PATH configuration
export PATH=$HOME/.local/bin:$PATH
EOF

# Coldark-Cold is a light theme and is illegible on a dark terminal. When the
# terminal background is dark, drop BAT_THEME so bat uses its dark default.
# Only act on a positive dark detection (see is_dark_terminal).
if is_dark_terminal; then
    sed -i '/^[[:space:]]*export BAT_THEME=/d' ~/.zshrc
    log "Dark terminal detected: removed bat's light theme (Coldark-Cold)"
fi
fi

# Migrate bash history to zsh if switching from bash
if [[ -f ~/.bash_history && "$SHELL" =~ bash ]]; then
    if prompt_yes_no "Migrate your bash history to zsh?" "Y"; then
        log "Migrating bash history to zsh..."

        # Backup existing zsh_history if it exists
        if [ -f ~/.zsh_history ]; then
            backup_file ~/.zsh_history
        fi

        # Convert bash history to zsh format using inline Python script
        # Based on: https://gist.github.com/muendelezaji/c14722ab66b505a49861b8a74e52b274
        if cat ~/.bash_history | python3 -c '
import sys
import time

timestamp = None
for line in sys.stdin.readlines():
    line = line.rstrip("\n")
    if line.startswith("#") and timestamp is None:
        t = line[1:]
        if t.isdigit():
            timestamp = t
            continue
    else:
        sys.stdout.write(": %s:0;%s\n" % (timestamp or int(time.time()), line))
        timestamp = None
' >> ~/.zsh_history 2>/dev/null; then
            log "Bash history successfully migrated to ~/.zsh_history"
        else
            log "Warning: Failed to migrate bash history. Continuing anyway..."
        fi
    else
        log "Skipping bash history migration"
    fi
else
    if [[ ! -f ~/.bash_history ]]; then
        log "No bash history file found, skipping migration"
    elif [[ ! "$SHELL" =~ bash ]]; then
        log "Current shell is not bash, skipping history migration"
    fi
fi

# Change default shell to zsh if not already zsh
log "Checking default shell..."
if [[ "$SHELL" != "/usr/bin/zsh" && "$SHELL" != "/bin/zsh" ]]; then
    if prompt_yes_no "Change default shell to zsh?" "Y"; then
        sudo chsh -s "$(command -v zsh)" "$USER"
        log "Default shell changed to zsh. You'll need to log out and back in for the change to take effect."
    else
        log "Keeping current shell: $SHELL"
    fi
else
    log "Shell is already set to zsh"
fi

# Suppress "Last login" banner on shell startup
if [ ! -f ~/.hushlogin ]; then
    log "Creating ~/.hushlogin to suppress login banner..."
    touch ~/.hushlogin
else
    log "~/.hushlogin already exists"
fi

# Configure PowerShell profile (light/dark-aware theme + cross-version QoL).
# Written even if pwsh isn't installed yet, so it's ready when it is. The profile
# itself works on Windows PowerShell 5.1 and PowerShell 7.2+, Windows and Linux.
PWSH_PROFILE="$HOME/.config/powershell/profile.ps1"
OVERWRITE_PWSH=true
if [ -f "$PWSH_PROFILE" ]; then
    if prompt_yes_no "Overwrite existing PowerShell profile?" "N"; then
        backup_file "$PWSH_PROFILE"
    else
        OVERWRITE_PWSH=false
        log "Keeping existing PowerShell profile"
    fi
fi

if [ "$OVERWRITE_PWSH" = true ]; then
    log "Configuring PowerShell profile..."
    mkdir -p "$HOME/.config/powershell"

    # Base quality-of-life settings (always written).
    cat > "$PWSH_PROFILE" << 'PWSHEOF'
# PowerShell profile - managed by linux-setup.sh
# UTF-8 for correct ANSI/glyph rendering. Wrapped: setting console encoding can
# throw when stdout is redirected / no real console is attached. Mostly a no-op
# on PS 7 (already UTF-8) but fixes glyphs on Windows PowerShell 5.1.
try {
    $OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
    [Console]::InputEncoding = [Text.UTF8Encoding]::new()
} catch {}

# ls-style helpers (-Force shows hidden; -Hidden alone would show ONLY hidden)
function l  { Get-ChildItem @args }
function la { Get-ChildItem -Force @args }
function ll { Get-ChildItem -Force @args }
# This is the All-Hosts profile, so reload that one (not $PROFILE = current-host)
function Update-Profile { . $PROFILE.CurrentUserAllHosts }
Set-Alias reload Update-Profile

Import-Module PSReadLine -ErrorAction SilentlyContinue
$hasPSReadLine = $null -ne (Get-Module PSReadLine)
if ($hasPSReadLine) {
    Set-PSReadLineOption -HistoryNoDuplicates -HistorySearchCursorMovesToEnd `
                         -BellStyle None -MaximumHistoryCount 10000
    Set-PSReadLineKeyHandler -Key Tab        -Function MenuComplete
    Set-PSReadLineKeyHandler -Key UpArrow    -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow  -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Chord 'Ctrl+LeftArrow'  -Function BackwardWord
    Set-PSReadLineKeyHandler -Chord 'Ctrl+RightArrow' -Function ForwardWord

    # Predictive IntelliSense - feature-detect (PSReadLine 2.1+; plugins need 7.2+).
    # Keep PowerShell's default InlineView (ListView warns in small / VS Code
    # windows); press F2 to switch to ListView - the ListPrediction colors cover it.
    if ((Get-Command Set-PSReadLineOption).Parameters.ContainsKey('PredictionSource')) {
        $src = if ($PSVersionTable.PSVersion -ge [version]'7.2') { 'HistoryAndPlugin' } else { 'History' }
        Set-PSReadLineOption -PredictionSource $src
    }
}
PWSHEOF

    # Apply the light theme only when the terminal is POSITIVELY light.
    # PowerShell's built-in colors are dark-optimized, so on an
    # undeterminable result we keep those defaults (unlike bat, which
    # defaults to light).
    if is_light_terminal; then
        log "Light terminal detected: applying PowerShell light theme"
        cat >> "$PWSH_PROFILE" << 'PWSHEOF'

# === Light-background theme (a light terminal was detected during setup) ===
# Colors mimic the PowerShell ISE light theme. PS 7.2+ uses the native $PSStyle
# API; Windows PowerShell 5.1 falls back to ConsoleColor names (no $PSStyle).
if ($PSVersionTable.PSVersion -ge [version]'7.2') {
    $ISETheme = @{
        Command                  = $PSStyle.Foreground.FromRGB(0x0000FF)
        Comment                  = $PSStyle.Foreground.FromRGB(0x006400)
        ContinuationPrompt       = $PSStyle.Foreground.FromRGB(0x0000FF)
        Default                  = $PSStyle.Foreground.FromRGB(0x0000FF)
        Emphasis                 = $PSStyle.Foreground.FromRGB(0x287BF0)
        Error                    = $PSStyle.Foreground.FromRGB(0xE50000)
        InlinePrediction         = $PSStyle.Foreground.FromRGB(0x93A1A1)
        Keyword                  = $PSStyle.Foreground.FromRGB(0x00008b)
        ListPrediction           = $PSStyle.Foreground.FromRGB(0x06DE00)
        Member                   = $PSStyle.Foreground.FromRGB(0x000000)
        Number                   = $PSStyle.Foreground.FromRGB(0x800080)
        Operator                 = $PSStyle.Foreground.FromRGB(0x757575)
        Parameter                = $PSStyle.Foreground.FromRGB(0x000080)
        String                   = $PSStyle.Foreground.FromRGB(0x8b0000)
        Type                     = $PSStyle.Foreground.FromRGB(0x008080)
        Variable                 = $PSStyle.Foreground.FromRGB(0xff4500)
        ListPredictionSelected   = $PSStyle.Background.FromRGB(0x93A1A1)
        Selection                = $PSStyle.Background.FromRGB(0x00BFFF)
    }
    if ($hasPSReadLine) { Set-PSReadLineOption -Colors $ISETheme }

    # Text formatting colors
    $PSStyle.Formatting.FormatAccent       = $PSStyle.Foreground.Green
    $PSStyle.Formatting.TableHeader        = $PSStyle.Foreground.Green
    $PSStyle.Formatting.ErrorAccent        = $PSStyle.Foreground.Cyan
    $PSStyle.Formatting.Error              = $PSStyle.Foreground.Red
    $PSStyle.Formatting.Warning            = $PSStyle.Foreground.Yellow
    $PSStyle.Formatting.Verbose            = $PSStyle.Foreground.Yellow
    $PSStyle.Formatting.Debug              = $PSStyle.Foreground.Yellow
    $PSStyle.Progress.Style                = $PSStyle.Foreground.Yellow

    # File system colors (listing files)
    $PSStyle.FileInfo.Directory            = $PSStyle.Background.FromRgb(0x2f6aff) + $PSStyle.Foreground.BrightWhite
    $PSStyle.FileInfo.SymbolicLink         = $PSStyle.Foreground.Cyan
    $PSStyle.FileInfo.Executable           = $PSStyle.Foreground.BrightMagenta
    $PSStyle.FileInfo.Extension['.ps1']    = $PSStyle.Foreground.Cyan
    $PSStyle.FileInfo.Extension['.ps1xml'] = $PSStyle.Foreground.Cyan
    $PSStyle.FileInfo.Extension['.psd1']   = $PSStyle.Foreground.Cyan
    $PSStyle.FileInfo.Extension['.psm1']   = $PSStyle.Foreground.Cyan
} elseif ($hasPSReadLine) {
    # Windows PowerShell 5.1: dark ConsoleColor names for contrast on white
    Set-PSReadLineOption -Colors @{
        Command   = 'DarkBlue'
        Parameter = 'DarkGray'
        Operator  = 'Black'
        String    = 'DarkCyan'
        Variable  = 'DarkGreen'
        Type      = 'DarkMagenta'
        Number    = 'DarkRed'
        Member    = 'Black'
        Comment   = 'Gray'
        Error     = 'Red'
    }
}
PWSHEOF
    else
        log "Dark/undetermined terminal: keeping PowerShell default (dark) colors"
    fi
fi

# Configure Terminator
if has_desktop_environment; then
    log "Configuring Terminator..."
    mkdir -p ~/.config/terminator

    # Check if Terminator config exists and prompt for overwrite
    OVERWRITE_TERMINATOR=true
    if [ -f ~/.config/terminator/config ]; then
        if prompt_yes_no "Overwrite existing Terminator config?" "N"; then
            backup_file ~/.config/terminator/config
        else
            OVERWRITE_TERMINATOR=false
            log "Keeping existing Terminator config"
        fi
    fi

    if [ "$OVERWRITE_TERMINATOR" = true ]; then
cat > ~/.config/terminator/config << 'EOF'
[global_config]
  focus = mouse
  enabled_plugins = LaunchpadBugURLHandler, LaunchpadCodeURLHandler, APTURLHandler, TabNumbers
  case_sensitive = False
  new_tab_after_current_tab = True
[keybindings]
  new_tab = <Primary>t
  cycle_next = ""
  cycle_prev = ""
  rotate_cw = ""
  rotate_ccw = ""
  split_horiz = <Super>y
  split_vert = <Super>a
  close_term = ""
  search = <Primary>f
  close_window = <Primary><Shift><Super>d
  move_tab_right = <Primary><Shift>Page_Down
  move_tab_left = <Primary><Shift>Page_Up
  next_tab = <Primary>Tab
  prev_tab = <Primary><Shift>Tab
  switch_to_tab_1 = <Primary>1
  switch_to_tab_2 = <Primary>2
  switch_to_tab_3 = <Primary>3
  switch_to_tab_4 = <Primary>4
  switch_to_tab_5 = <Primary>5
  switch_to_tab_6 = <Primary>6
  group_tab = ""
  insert_number = <Super>n
  edit_tab_title = <Super>q
  edit_terminal_title = <Super>t
[profiles]
  [[default]]
    background_color = "#282828"
    background_darkness = 1.0
    cursor_fg_color = "#300a24"
    cursor_bg_color = "#ffffff"
    font = Fira Code Medium 14
    foreground_color = "#ebdbb2"
    scrollback_infinite = True
    use_system_font = False
    use_theme_colors = True
    copy_on_selection = True
[layouts]
  [[default]]
    [[[window0]]]
      type = Window
      parent = ""
    [[[child1]]]
      type = Terminal
      parent = window0
[plugins]
EOF
    fi

    # Install Terminator tab numbers plugin
    log "Installing Terminator tab numbers plugin..."
    mkdir -p ~/.config/terminator/plugins

    if [[ ! -f ~/.config/terminator/plugins/tab_numbers.py ]]; then
        if curl --proto '=https' --tlsv1.2 -fsSL -o ~/.config/terminator/plugins/tab_numbers.py https://raw.githubusercontent.com/c0ffee0wl/terminator-tab-numbers-plugin/main/tab_numbers.py; then
            log "Terminator tab numbers plugin installed successfully"
        else
            warn "Failed to download Terminator tab numbers plugin"
        fi
    else
        log "Terminator tab numbers plugin is already installed"
    fi
else
    log "No desktop environment detected - skipping Terminator configuration"
fi

# Configure tmux (self-contained sensible defaults, emacs keybindings).
# tmux is a headless CLI tool, so this is written regardless of desktop.
log "Configuring tmux..."
OVERWRITE_TMUX=true
if [ -f ~/.tmux.conf ]; then
    if prompt_yes_no "Overwrite existing tmux config?" "N"; then
        backup_file ~/.tmux.conf
    else
        OVERWRITE_TMUX=false
        log "Keeping existing tmux config"
    fi
fi

if [ "$OVERWRITE_TMUX" = true ]; then
cat > ~/.tmux.conf << 'EOF'
# tmux configuration - managed by linux-setup.sh
# Self-contained sensible defaults; no plugin manager, no network deps.

# --- Keys: emacs everywhere (matches zsh's emacs-style line editing) ---
set -g mode-keys emacs       # copy-mode navigation/selection
set -g status-keys emacs     # command-prompt editing
# Prefix stays at the default C-b (C-a is emacs/readline beginning-of-line).

# --- General behaviour ---
set -g mouse on              # click panes, drag borders, wheel-scroll
set -g history-limit 50000   # large scrollback for long command output
set -s escape-time 10        # near-instant Esc without misreading split escape sequences (e.g. over SSH)
set -g focus-events on       # let apps (e.g. editors) see focus in/out
set -g display-time 4000     # status messages stay readable (4s)
set -g status-interval 5     # refresh the status line every 5s
setw -g aggressive-resize on

# --- Windows/panes start at 1, renumber on close ---
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g allow-rename off       # keep custom window names (set via prefix ,) from being overridden

# --- Colour: 256-colour + truecolor passthrough ---
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB,*256col*:RGB"

# --- System clipboard (OSC 52); 'on' lets apps inside tmux set the host clipboard ---
set -s set-clipboard on

# --- New windows/splits open in the current pane's directory ---
# Default split keys (" and %) are kept; |/- and y/a added as intuitive aliases.
bind c   new-window      -c "#{pane_current_path}"
bind '"' split-window -v -c "#{pane_current_path}"
bind %   split-window -h -c "#{pane_current_path}"
bind |   split-window -h -c "#{pane_current_path}"
bind -   split-window -v -c "#{pane_current_path}"
bind y   split-window -v -c "#{pane_current_path}"
bind a   split-window -h -c "#{pane_current_path}"

# --- Quick reload ---
bind r source-file ~/.tmux.conf \; display-message "tmux.conf reloaded"
EOF
fi

#############################################################################
# Source-built CLI tools
#############################################################################
# Run last, after every config write (.zshrc, chsh, PowerShell profile,
# Terminator, tmux) and the supply-chain hardening. A failed build here - an
# OOM 'signal: killed' on a low-RAM VM, a transient network/upstream error -
# is now non-fatal (note_build_failure), but running these last also means an
# unexpected *fatal* error can never abort the script before the shell is set
# up. Each tool is optional and guarded in the embedded .zshrc.
# Install up tool. Upstream github.com/akavel/up is discontinued/archived, so
# freeze the installed build: "once" makes install_go_tool skip the rebuild when
# 'up' is already on PATH (it lives in /usr/local/bin, always on PATH). This also
# avoids pulling a potentially hijacked @latest from a dormant namespace.
install_go_tool "up" "github.com/akavel/up@latest" once
sudo cp "$HOME/go/bin/up" /usr/local/bin/ 2>/dev/null || true

# Configure AppArmor to allow bwrap to create user namespaces
# Ubuntu 24.04+ restricts unprivileged user namespaces via AppArmor by default,
# which breaks bwrap sandboxing (used by the 'up' and 'polster' aliases)
if command -v apparmor_parser &> /dev/null && \
   [ -d /sys/module/apparmor ] && \
   [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] && \
   [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)" = "1" ] && \
   [ ! -f /etc/apparmor.d/bwrap ]; then
    log "Configuring AppArmor profile for bwrap..."
    if sudo tee /etc/apparmor.d/bwrap > /dev/null <<'APPARMOR'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,

  include if exists <local/bwrap>
}
APPARMOR
    then
        sudo apparmor_parser -r /etc/apparmor.d/bwrap || warn "Failed to load AppArmor bwrap profile"
    else
        warn "Failed to write AppArmor bwrap profile"
    fi
else
    log "AppArmor bwrap profile already configured or not needed"
fi

# Install Go-based tools
GO_VERSION=$(get_go_version)
MINIMUM_GO_VERSION=124  # Go 1.24

install_go_tool "eget" "github.com/zyedidia/eget@latest"

# yq and lazygit: prefer a recent apt package, else build with 'go install'
# (needs Go 1.24+). yq's apt package is 'yq-go' (binary yq-go); we symlink 'yq'.
install_go_tool_apt "yq"      "yq-go"   "$YQ_MIN"      "github.com/mikefarah/yq/v4@latest"       "yq-go"   "$MINIMUM_GO_VERSION"
install_go_tool_apt "lazygit" "lazygit" "$LAZYGIT_MIN" "github.com/jesseduffield/lazygit@latest" "lazygit" "$MINIMUM_GO_VERSION"

# lazydocker and gitsnip are not packaged in Debian/Ubuntu/Kali - always build (Go 1.24+)
if [ "$GO_VERSION" -ge "$MINIMUM_GO_VERSION" ]; then
    install_go_tool "lazydocker" "github.com/jesseduffield/lazydocker@latest"
    install_go_tool "gitsnip" "github.com/dagimg-dot/gitsnip/cmd/gitsnip@latest"
else
    GO_VERSION_STR=$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+' | head -1 || true)
    warn "Skipping lazydocker and gitsnip - require Go 1.24+, found Go ${GO_VERSION_STR:-unknown}"
fi


# Install zoxide: prefer a recent apt package (Kali/sid ship 0.9.x), else the
# official installer (prebuilt binary into ~/.local/bin, first on PATH; the
# script is fetched to a file so a truncated transfer can't execute). apt is
# preferred because the installer's unauthenticated GitHub API call rate-limits
# per IP and then fails with a misleading "not packaged for your arch" error.
if apt_meets_min "zoxide" "$ZOXIDE_MIN"; then
    install_apt_package "zoxide" "zoxide"
    # Drop a stale installer-placed copy so the apt binary wins on PATH
    rm -f "$HOME/.local/bin/zoxide"
else
    log "Installing/updating zoxide via official install script..."
    ZOXIDE_INSTALLER=$(mktemp)
    # Non-fatal: a failed download/install records zoxide and continues (the
    # .zshrc guards 'zoxide init' with $+commands[zoxide]). '&&'/'||' are
    # left-associative, so this is (curl && sh) || note_build_failure.
    curl --proto '=https' --tlsv1.2 -sSfL \
        https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \
        -o "$ZOXIDE_INSTALLER" \
        && sh "$ZOXIDE_INSTALLER" --bin-dir "$HOME/.local/bin" \
        || note_build_failure "zoxide"
    rm -f "$ZOXIDE_INSTALLER"
fi
remove_source_builds "zoxide"   # drop stale ~/.cargo/bin copies from old runs

# Install sd and delta: prefer a recent apt package (skips the cargo compile),
# else build via cargo.
install_cargo_tool "sd"     "sd"        "sd"        "$SD_MIN"
install_cargo_tool "delta"  "git-delta" "git-delta" "$DELTA_MIN"

# Configure delta as git pager
if command -v delta &> /dev/null; then
    log "Configuring delta as git pager..."
    git config --global core.pager "delta"
    git config --global interactive.diffFilter "delta --color-only"
    git config --global delta.navigate "true"
    git config --global merge.conflictstyle "zdiff3"
fi

# procs (modern ps) and dust (modern du, binary 'dust' from the du-dust package):
# repo-only, no cargo fallback - install_apt_only skips releases that lack them.
install_apt_only "procs" "procs"
install_apt_only "dust"  "du-dust"

if is_kali_linux && [ "$NO_HACKING_TOOLS" != true ]; then

    # Install Project Discovery tool manager (Kali-specific tools)
    install_go_tool "pdtm" "github.com/projectdiscovery/pdtm/cmd/pdtm@latest"
    
    # Install all Project Discovery tools
    log "Installing all Project Discovery tools..."
    if command -v pdtm &> /dev/null; then
        log "Updating pdtm itself..."
        pdtm -self-update
        log "Installing all tools..."
        pdtm -install-all
        log "Updating all tools..."
        pdtm -update-all
    else
        warn "pdtm installation failed, skipping tool installation"
    fi

    # Install BloodHoundAnalyzer (Kali-specific tools)
    if [[ ! -d /opt/BloodHoundAnalyzer ]]; then
        log "Installing BloodHoundAnalyzer..."
        sudo git clone --depth=1 https://github.com/c0ffee0wl/BloodHoundAnalyzer /opt/BloodHoundAnalyzer
        sudo chown -R "$(whoami)":"$(whoami)" /opt/BloodHoundAnalyzer
        (cd /opt/BloodHoundAnalyzer && ./install.sh) || warn "BloodHoundAnalyzer installation script failed"
    else
        log "BloodHoundAnalyzer is already installed"
    fi

    # Install Python tools with uv (Kali-specific tools)
    log "Installing Python tools for Kali with uv..."
    if command -v uv &> /dev/null; then
        uv tool install --force bbot
        uv tool install --force git+https://github.com/Pennyw0rth/NetExec
    else
        warn "uv not available, skipping Python tools installation"
    fi
    
else
    log "Skipping Kali tools installation"
fi

# Install and configure ufw-docker
log "Installing ufw-docker..."
if ! command -v ufw-docker &> /dev/null; then
    # Download UFW-Docker script
    sudo curl --proto '=https' --tlsv1.2 -fsSL -o /usr/local/bin/ufw-docker https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
    sudo chmod +x /usr/local/bin/ufw-docker
    
    log "ufw-docker installed successfully"
else
    log "ufw-docker is already installed"
fi
# Apply ufw-docker rules only when the firewall is already active. We never enable
# ufw ourselves (that risks SSH lockout), so this fires only on an already-firewalled
# box. LC_ALL is passed on sudo's command line (sudo resets the env, so the global
# export doesn't reach it) to force a locale-independent "Status: active" match.
if command -v docker &> /dev/null && command -v ufw &> /dev/null \
        && sudo LC_ALL=C.UTF-8 ufw status 2>/dev/null | grep -Fq "Status: active"; then
    if sudo grep -q "^# BEGIN UFW AND DOCKER" /etc/ufw/after.rules 2>/dev/null; then
        log "ufw-docker rules already present in /etc/ufw/after.rules; nothing to do"
    else
        warn "ufw is active. Applying ufw-docker BLOCKS external access to all published"
        warn "Docker container ports (FORWARD/DOCKER-USER chain only - host services like"
        warn "SSH are unaffected). Re-expose a port with: sudo ufw-docker allow <container> <port>"
        published="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -F '->' || true)"
        [[ -n "$published" ]] && { warn "Currently published containers:"; printf '%s\n' "$published"; }
        if prompt_yes_no "Apply ufw-docker firewall rules now?" "Y"; then
            if sudo ufw-docker install; then
                sudo ufw reload || warn "ufw reload failed; run 'sudo ufw reload' manually to apply the rules"
                log "ufw-docker rules applied. Expose a port with: sudo ufw-docker allow <container> <port>"
            else
                warn "ufw-docker install failed; apply manually with: sudo ufw-docker install && sudo ufw reload"
            fi
        else
            log "Skipped applying ufw-docker rules"
        fi
    fi
else
    log "ufw is not active; skipping ufw-docker rules"
    log "To harden Docker ports later: sudo ufw enable && sudo ufw-docker install && sudo ufw reload"
fi

# Configure systemd-resolved to disable stub listener if installed
log "Configuring systemd-resolved..."
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    log "systemd-resolved is active, configuring..."
    sudo mkdir -p /etc/systemd/resolved.conf.d/
    write_config_file --sudo /etc/systemd/resolved.conf.d/disable-stub.conf << 'EOF'
[Resolve]
DNSStubListener=no
EOF
    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    sudo systemctl restart systemd-resolved || true
    log "systemd-resolved configured successfully"
else
    log "systemd-resolved not active, skipping configuration"
fi

# Disable avahi-daemon
log "Disabling avahi-daemon..."
if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    log "avahi-daemon is active, disabling..."
    sudo systemctl stop avahi-daemon || true
    sudo systemctl disable avahi-daemon || true
    log "avahi-daemon disabled successfully"
else
    log "avahi-daemon not active, skipping configuration"
fi

# Final cleanup
log "Performing final cleanup..."
apt_get autoremove -y
apt_get clean
go clean -cache -modcache || true
uv cache clean || true
rm -rf "$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/src" "$HOME/.cargo/git/checkouts" 2>/dev/null || true

# Configure Xfce keyboard layout to German
if [[ "$NO_KEYBOARD_LAYOUT" == "true" ]]; then
    log "Skipping keyboard layout configuration (--no-keyboard-layout)"
elif has_desktop_environment; then
    if command -v xfconf-query &> /dev/null; then
        if prompt_yes_no "Configure German keyboard layout in XFCE?" "N"; then
            log "Configuring Xfce keyboard layout to German..."
            xfconf-query -c keyboard-layout -p /Default/XkbDisable --create -t bool -s false || true
            xfconf-query -c keyboard-layout -p /Default/XkbLayout --create -t string -s "de" || true
            log "German keyboard layout configured"
        else
            log "Skipping keyboard layout configuration"
        fi
    else
        warn "xfconf-query not available, skipping keyboard layout configuration"
    fi
else
    log "No desktop environment detected - skipping keyboard layout configuration"
fi

# Free <Super>q for Terminator's rename-tab binding. XFCE has no default on
# Super+Q, but clear any stray binding so the chord reaches Terminator. We no
# longer touch <Super>e, so XFCE's built-in file-manager shortcut keeps working.
if has_desktop_environment; then
    if command -v xfconf-query &> /dev/null; then
        log "Deleting XFCE <Super>q shortcut so Terminator can use it..."
        xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/<Super>q" -r 2>/dev/null || true
        xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/default/<Super>q" -r 2>/dev/null || true
    fi
fi

if [ ${#FAILED_BUILDS[@]} -gt 0 ]; then
    warn "These optional source-built tools were skipped after a failed build:"
    for t in "${FAILED_BUILDS[@]}"; do warn "  - $t"; done
    warn "Your shell is fully configured regardless. Re-run to retry (on low-RAM VMs, add swap first)."
fi

log "Setup complete!"
echo -e "${BLUE}===========================================${NC}"
echo -e "${BLUE}  Linux Setup Complete!${NC}"
echo -e "${BLUE}===========================================${NC}"

echo
echo -e "${YELLOW}Please log out and log back in for all changes to take effect.${NC}"
echo
echo -e "${BLUE}===========================================${NC}"
echo -e "${BLUE}  Self-Update Information${NC}"
echo -e "${BLUE}===========================================${NC}"
echo
echo -e "This script has a ${GREEN}built-in self-update mechanism${NC} and can be safely re-executed."
echo -e "When you run it again, it will automatically check for and apply any updates."
echo
echo -e "${YELLOW}TIP: Keep the cloned directory - don't delete it!${NC}"
echo -e "This allows you to re-run the script whenever you want to:"
echo -e "  • Get the latest updates and improvements"
echo -e "  • Reapply configurations"
echo -e "  • Install newly added tools"
echo
echo -e "${BLUE}Automation Options:${NC}"
echo -e "  • Use ${GREEN}--yes${NC} or ${GREEN}-y${NC} to automatically answer 'Yes' to all prompts"
echo -e "  • Use ${GREEN}--no${NC} or ${GREEN}-n${NC} to automatically answer 'No' to all prompts"
