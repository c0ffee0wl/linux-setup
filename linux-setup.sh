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

VERSION="2.22.0"
FORCE_MODE=false
NO_MODE=false
NO_HACKING_TOOLS=false
HARDEN_ONLY=false
NO_KEYBOARD_LAYOUT=false
NO_SWAP=false

# Go module supply-chain policy - single source for the persistent exports in
# ~/.profile (apply_supply_chain_hardening) and the in-process exports in
# install_go_tool (needed because ~/.profile doesn't affect the running script).
GOPROXY_HARDENED="https://proxy.golang.org,off"
GOSUMDB_HARDENED="sum.golang.org"

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
  --no-swap            Never create the temporary low-RAM swapfile
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
        --no-swap)
            NO_SWAP=true
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
    warn "$1 failed to install (continuing without it)"
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
# untouched so re-runs cause no backup churn. Sets the global CONFIG_CHANGED
# (true|false, valid until the next call) so callers can gate follow-up actions
# like service restarts on an actual change.
# Usage: write_config_file [--sudo] [--mode <octal>] [--keep-existing] <dest> << 'EOF' ... EOF
#   --keep-existing: never touch an existing dest (create-only semantics)
write_config_file() {
    local sudo_cmd="" mode="644" keep_existing=false
    while :; do
        case "$1" in
            --sudo) sudo_cmd="sudo"; shift ;;
            --mode) mode="$2"; shift 2 ;;
            --keep-existing) keep_existing=true; shift ;;
            *) break ;;
        esac
    done
    local dest="$1" tmp
    CONFIG_CHANGED=false
    tmp=$(mktemp)
    cat > "$tmp"    # heredoc stdin into a real file (never install /dev/stdin)
    if [ -f "$dest" ] && { [ "$keep_existing" = true ] || cmp -s "$tmp" "$dest"; }; then
        rm -f "$tmp"
        return 0
    fi
    backup_file ${sudo_cmd:+--sudo} "$dest"
    $sudo_cmd install -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
    CONFIG_CHANGED=true
}

# Install a rendered user config from a temp file, with overwrite prompting:
# identical content -> kept silently (no prompt, no backup churn); differing
# content -> prompt (per-caller default), then delegate to write_config_file,
# which owns the backup + install mechanics and sets CONFIG_CHANGED. Consumes
# (removes) the temp file and always returns 0, so call sites are 'set -e'-safe.
# Usage: install_user_config <src_tmp> <dest> <prompt> <default Y|N>
install_user_config() {
    local src="$1" dest="$2" prompt="$3" default="$4"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        log "$dest is already up to date"
        CONFIG_CHANGED=false
    elif [ -f "$dest" ] && ! prompt_yes_no "$prompt" "$default"; then
        log "Keeping existing $dest"
        CONFIG_CHANGED=false
    else
        write_config_file "$dest" < "$src"
    fi
    rm -f "$src"
}

# apt-get wrapper: in force/no mode run fully non-interactively so debconf
# dialogs, dpkg conffile prompts, and Ubuntu's needrestart menu can't stall
# unattended runs. sudo resets the environment, so the variables are passed
# on sudo's command line rather than exported. DPkg::Lock::Timeout makes apt
# wait for the lock instead of aborting when a boot-time apt job (cloud-init,
# apt-daily, unattended-upgrades) still holds it - the classic cloud-init race.
# Acquire::Retries re-fetches transiently failed downloads (flaky networking
# right after a cloud VM boots) instead of failing the whole transaction.
apt_get() {
    if [[ "$FORCE_MODE" == "true" || "$NO_MODE" == "true" ]]; then
        sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
            -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
    else
        sudo apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 "$@"
    fi
}

# curl wrapper owning the download policy for every fetch in this script:
# HTTPS-only, TLS >= 1.2, fail on HTTP errors, bounded timeouts so an
# unreachable host can't stall the run, and bounded retries on transient
# failures (timeouts, 408/429/5xx, connection refused - early-boot networking
# on cloud VMs). --retry-max-time caps the CUMULATIVE retry window: --max-time
# resets per attempt, so without it a repeatedly stalling transfer could run
# retries x 300s (~20 min). Deliberately NOT --retry-all-errors: that would
# also retry deterministic failures like 404, breaking repo_suite_published's
# fast absence-probe semantics and masking real errors. Callers append extra
# flags (e.g. -o <file>); later flags override these defaults.
fetch_url() {
    curl --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 300 \
        --retry 3 --retry-delay 2 --retry-max-time 300 --retry-connrefused -fsSL "$@"
}

# True when the vendor publishes an apt suite at <base_url>/dists/<suite>/Release.
# Used to pick a repo suite by capability instead of maintaining codename lists
# (Docker and PowerShell repos); tighter timeouts than fetch_url's defaults
# because a probe should fail fast.
repo_suite_published() {
    fetch_url --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 1 \
        --retry-max-time 15 -I "$1/dists/$2/Release" > /dev/null 2>&1
}

# Download <url> to a mktemp file, then install it atomically at <dest>, so a
# truncated download can never land at the destination (or satisfy a
# command -v re-run gate with a broken file). Returns the fetch status, so
# each caller keeps its own fatal/warn policy.
# Usage: fetch_install [--sudo] [--mode <octal>] <url> <dest>
fetch_install() {
    local sudo_cmd="" mode="644"
    while :; do
        case "$1" in
            --sudo) sudo_cmd="sudo"; shift ;;
            --mode) mode="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    local url="$1" dest="$2" tmp rc=0
    tmp=$(mktemp)
    if fetch_url -o "$tmp" "$url"; then
        $sudo_cmd install -m "$mode" "$tmp" "$dest"
    else
        rc=1
    fi
    rm -f "$tmp"
    return $rc
}

# A bare read failed with nothing captured: stdin is closed or exhausted (no
# TTY - cloud-init/CI - or a finite piped stdin that ran out). Without this,
# set -e would kill the run on the failed read with no explanation. Mirrors
# the embedded upgrade-to-kali helper's non-tty stance.
prompt_eof_abort() {
    echo   # terminate the read -p prompt line (EOF echoed no newline)
    error "No input available to answer: '$1'. Re-run with --force (auto-yes) or --no (auto-no) for unattended use."
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

    local suffix="(y/N)"
    [[ "$default" == "Y" ]] && suffix="(Y/n)"
    # `|| [ -n "$response" ]` salvages a final line without trailing newline
    # (read still populates the variable on an EOF-terminated last line).
    read -p "$prompt $suffix: " response || [ -n "$response" ] || prompt_eof_abort "$prompt"
    response=${response:-$default}

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

# True when Kali pentest tooling should be installed (on Kali, not opted out).
want_hacking_tools() {
    is_kali_linux && [ "$NO_HACKING_TOOLS" != true ]
}

# Check if we're on Ubuntu or Ubuntu-based distribution
is_ubuntu() {
    local ID ID_LIKE
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        [ "$ID" = "ubuntu" ] || [[ "$ID_LIKE" == *ubuntu* ]]
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

    # Composed once so the fast-path check and the writers stay in lockstep
    local export_line="export ${var_name}=\"${escaped_value}\""

    # No-op fast path: the exact export line is already present
    if grep -qxF "$export_line" "$profile_file" 2>/dev/null; then
        return 0
    fi

    # For sed replacement, also escape & (special in replacement string)
    local sed_value="$escaped_value"
    sed_value="${sed_value//&/\\&}"              # & -> \&

    if grep -q "^export ${var_name}=" "$profile_file" 2>/dev/null; then
        # Update existing export in place
        sed -i "s|^export ${var_name}=.*|export ${var_name}=\"${sed_value}\"|" "$profile_file"
    else
        # Append new export
        echo "$export_line" >> "$profile_file"
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

# Hardening config bodies - each defined once and deployed to both the
# user-level and system-level (defence-in-depth) locations by
# apply_supply_chain_hardening, so the two copies cannot drift.
emit_npmrc() {
    cat << 'EOF'
ignore-scripts=true
save-exact=true
audit=true
fund=false
min-release-age=7
minimum-release-age=10080
EOF
}

emit_uv_toml() {
    cat << 'EOF'
exclude-newer = "1 week"
system-certs = true
python-preference = "system"
EOF
}

emit_pip_conf() {
    cat << 'EOF'
[global]
prefer-binary = true

[install]
prefer-binary = true
EOF
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
    # Process substitution, not a pipe: a pipe would run write_config_file in a
    # subshell and silently discard the CONFIG_CHANGED global it sets.
    write_config_file "$HOME/.npmrc" < <(emit_npmrc)

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
    write_config_file --keep-existing "$HOME/.cargo/config.toml" << 'EOF'
[net]
git-fetch-with-cli = true
EOF

    # --- Python package manager hardening (user-level) ---
    log "Configuring Python package manager hardening..."
    mkdir -p "$HOME/.config/uv" "$HOME/.config/pip"

    write_config_file "$HOME/.config/uv/uv.toml" < <(emit_uv_toml)
    write_config_file "$HOME/.config/pip/pip.conf" < <(emit_pip_conf)

    # --- System-level fallback configs (defence-in-depth) ---
    # If user deletes their dotfiles, system defaults still enforce hardening
    log "Deploying system-level fallback configs..."
    if sudo -n true 2>/dev/null; then
        sudo mkdir -p /usr/local/etc /etc/uv

        write_config_file --sudo /usr/local/etc/npmrc < <(emit_npmrc)
        write_config_file --sudo /etc/uv/uv.toml < <(emit_uv_toml)
        write_config_file --sudo /etc/pip.conf < <(emit_pip_conf)

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
    update_profile_export "GOPROXY" "$GOPROXY_HARDENED"
    update_profile_export "GOSUMDB" "$GOSUMDB_HARDENED"

    # Go telemetry opt-out (Go 1.23+ writes mode to ~/.config/go/telemetry/mode)
    command -v go &>/dev/null && go telemetry off 2>/dev/null || true

    # Ensure ZSH sources ~/.profile on non-Kali systems
    ensure_zprofile_sources_profile

    log "Supply-chain hardening complete"
}

# Check if desktop environment is available. The probe result is cached in the
# global HAS_DESKTOP (yes|no) after the first call (same pattern as
# TERMINAL_BG): the check runs many times per run, and on headless systems it
# falls through to a dpkg scan of the whole package database every time.
HAS_DESKTOP=""
has_desktop_environment() {
    if [ -z "$HAS_DESKTOP" ]; then
        HAS_DESKTOP=no
        # Desktop session files (most reliable), then display manager config,
        # then common DE packages (Kali uses XFCE). Keep the package list in
        # sync with has_desktop in the upgrade-to-kali heredoc.
        if [ -d /usr/share/xsessions ] && [ -n "$(ls -A /usr/share/xsessions 2>/dev/null)" ]; then
            HAS_DESKTOP=yes
        elif [ -d /usr/share/wayland-sessions ] && [ -n "$(ls -A /usr/share/wayland-sessions 2>/dev/null)" ]; then
            HAS_DESKTOP=yes
        elif [ -s /etc/X11/default-display-manager ]; then
            HAS_DESKTOP=yes
        elif dpkg -l 2>/dev/null | grep -qE '^ii\s+(xfce4|gnome-shell|kde-plasma-desktop|plasma-desktop|lxde-core|mate-desktop-environment|cinnamon)'; then
            HAS_DESKTOP=yes
        fi
    fi
    [ "$HAS_DESKTOP" = "yes" ]
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
    echo "$v" | awk -F. '{print ($1 * 100) + $2}'
}

# Get installed Go version as comparable number (e.g., 1.24 -> 124, missing ->
# 0). Memoized in GO_VER_NUM - it's an invariant per run (the Go toolchain is
# installed in Phase 1, before any caller) and each probe costs a pipeline.
GO_VER_NUM=""
get_go_version() {
    if [ -z "$GO_VER_NUM" ]; then
        local go_version
        go_version=$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+' | head -1 || true)
        GO_VER_NUM=$(version_to_num "$go_version")
    fi
    echo "$GO_VER_NUM"
}

# Per-tool minimum apt versions (compared via version_to_num, e.g. "0.9" -> 9).
# Decide apt-vs-source per tool; keep in sync with the install calls further down.
ZOXIDE_MIN=9      # zoxide >= 0.9  (Kali/sid ship 0.9.x; Debian <=12 / Ubuntu 22.04 ship 0.4.3)
SD_MIN=7          # sd     >= 0.7  (bookworm's 0.7.6 is usable; older/absent -> build)
DELTA_MIN=16      # delta  >= 0.16 (Ubuntu 24.04 LTS ships 0.16.5)
LAZYGIT_MIN=50    # lazygit>= 0.50 (Debian 13 / Kali have it; older -> go install)
YQ_MIN=400        # yq-go  >= 4.0  (mikefarah yq; Kali/sid ship 4.53)
PWSH_MIN=700      # powershell >= 7.0 (Kali ships 7.5.x natively; else Microsoft repo)
RUSTC_MIN=185     # rustc  >= 1.85 (dev-runtime minimum for modern tools; else rustup)
GO_MIN=124        # go     >= 1.24 (needed to build the source-built Go tools)

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
# Usage: install_go_tool <tool-name> <go-package-path> [mode] [min_go]
#   mode:   "update" (default) rebuilds @latest every run.
#           "once" skips the build when <tool-name> is already on PATH - use for
#           discontinued/archived upstreams we want to freeze at the installed build
#           (also avoids pulling @latest from a dormant, hijackable namespace).
#   min_go: minimum get_go_version needed to build (0 = no requirement); the
#           tool is skipped with a warning when the installed Go is older.
install_go_tool() {
    local tool_name="$1"
    local package_path="$2"
    local mode="${3:-update}"
    local min_go="${4:-0}"

    if [ "$min_go" -gt 0 ]; then
        local go_num
        go_num=$(get_go_version)
        if [ "$go_num" -lt "$min_go" ]; then
            warn "Skipping ${tool_name} - requires Go >= $((min_go / 100)).$((min_go % 100)), found $((go_num / 100)).$((go_num % 100))"
            return 0
        fi
    fi
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
    export GOPROXY="$GOPROXY_HARDENED"
    export GOSUMDB="$GOSUMDB_HARDENED"
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
# repos). Rebuilt on every run, never cached across runs: Microsoft rotates
# signing keys (microsoft.asc signs pre-2025 repos like repos/code,
# microsoft-rolling.asc carries the current and future keys), so a stale keyring
# breaks apt-get update. Within one run the first refresh suffices, so repeat
# calls (re-run refresh, VS Code block, PowerShell block) return early.
MS_KEYRING_REFRESHED=false
ensure_microsoft_keyring() {
    [ "$MS_KEYRING_REFRESHED" = true ] && return 0
    command -v gpg &> /dev/null || apt_get install -y gpg
    local tmp_keyring
    tmp_keyring=$(mktemp)
    fetch_url \
        https://packages.microsoft.com/keys/microsoft.asc \
        https://packages.microsoft.com/keys/microsoft-rolling.asc | gpg --dearmor > "$tmp_keyring"
    sudo install -m 644 "$tmp_keyring" /usr/share/keyrings/microsoft.gpg
    rm -f "$tmp_keyring"
    MS_KEYRING_REFRESHED=true
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
#   min_go:  forwarded to install_go_tool's min-Go gate in the source-build fallback.
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
    else
        install_go_tool "$bin" "$go_pkg" update "$min_go"
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

    # Download and run rustup-init - fetched to a file first so a truncated
    # transfer can't execute (same idiom as the zoxide installer below).
    # RUSTUP_INIT_SKIP_PATH_CHECK silences the "existing Rust at /usr/bin"
    # warning when apt's rustc is also installed — ~/.cargo/bin is prepended
    # to PATH in .zshrc so rustup's toolchain wins.
    local rustup_init
    rustup_init=$(mktemp)
    fetch_url -o "$rustup_init" https://sh.rustup.rs
    RUSTUP_INIT_SKIP_PATH_CHECK=yes sh "$rustup_init" -y --default-toolchain stable
    rm -f "$rustup_init"

    # Source cargo environment for this script
    export CARGO_HOME="$HOME/.cargo"
    export RUSTUP_HOME="$HOME/.rustup"
    export PATH="$CARGO_HOME/bin:$PATH"

    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env" || true
    fi

    log "Rust installed successfully via rustup"
}

#############################################################################
# Low-RAM / low-disk accommodations (1 GB cloud droplets)
#############################################################################
# Env-overridable for testing without a real 1 GB VM (mirrors the embedded
# upgrade-to-kali pattern): LOW_MEM_KIB=99999999 forces the low-RAM path.
LOW_MEM_KIB="${LOW_MEM_KIB:-2000000}"        # ~1.9 GiB: below this, swap + throttled builds
LOW_DISK_KIB="${LOW_DISK_KIB:-5242880}"      # 5 GiB: below this, warn only (never fatal)
SWAP_FILE="${SWAP_FILE:-/linux-setup.swap}"  # distinctive name - never a user's /swapfile;
                                             # deliberately not a dotfile so du/ncdu show it
SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-2048}"       # preferred; shrunk to 1024 when / is tight
SWAP_MIN_FREE_MIB=4096                       # must remain free on / AFTER creating the file
SWAP_ACTIVE=false                            # true while our swapfile is swapon'd

free_kib()      { df -Pk "$1" | awk 'NR==2 {print $4}'; }
mem_total_kib() { awk '/^MemTotal:/{print $2}' /proc/meminfo; }
# Note: a nominal-2GB VM's MemTotal lands near LOW_MEM_KIB after kernel
# reservations and may fall on either side - both outcomes are safe (extra
# swap is harmless, throttling only slows builds). 1 GB VMs are always caught.
is_low_memory() { [ "$(mem_total_kib)" -lt "$LOW_MEM_KIB" ]; }
any_swap_active() { [ "$(wc -l < /proc/swaps)" -gt 1 ]; }  # header + >= 1 entry (incl. zram)

# Warn-only free-space check on / (never fatal; a run may still succeed, and
# setup_temp_swap does its own stricter sizing math).
check_disk_space() {
    local avail
    avail=$(free_kib /)
    if [ "${avail:-0}" -lt "$LOW_DISK_KIB" ]; then
        warn "Low disk space: only $(( avail / 1024 )) MiB free on / (recommended: >= $(( LOW_DISK_KIB / 1024 / 1024 )) GiB). Continuing, but installs may fail."
    fi
}

# EXIT-trap cleanup: swapoff + delete the temporary swapfile. Idempotent
# (SWAP_ACTIVE guard) and tolerant: runs from the EXIT trap, so nothing in
# here may fail the trap body or change the script's exit status.
cleanup_temp_swap() {
    [ "$SWAP_ACTIVE" = true ] || return 0
    log "Removing temporary swapfile ${SWAP_FILE}..."
    if sudo swapoff "$SWAP_FILE" 2>/dev/null; then
        sudo rm -f "$SWAP_FILE" 2>/dev/null || true
        SWAP_ACTIVE=false
        log "Temporary swap removed"
    else
        # swapoff fails when swapped pages exceed free RAM (abort under memory
        # pressure) or sudo can't re-authenticate inside the trap. Leave the
        # file: the next run adopts and removes it.
        warn "Could not release ${SWAP_FILE} now. Remove it later with:"
        warn "  sudo swapoff ${SWAP_FILE} && sudo rm -f ${SWAP_FILE}"
    fi
    return 0
}

# Shared activate tail: flag + EXIT-trap arm + user notice, so every path
# that turns swap on also arms the cleanup.
mark_swap_active() {
    SWAP_ACTIVE=true
    trap cleanup_temp_swap EXIT
    log "Temporary swap active (auto-removed when the script exits)"
}

# Create a temporary swapfile on low-RAM machines so the dist-upgrade, source
# builds, and pdtm can't be OOM-killed (cloud VMs ship with zero swap).
# Removed by cleanup_temp_swap via the EXIT trap. MUST be called after the
# Phase 0 self-update: bash EXIT traps do not survive exec, so a trap armed
# before the re-exec would never fire and the swapfile would leak. Only an
# EXIT trap is used - bash runs it on set -e aborts and fatal signals too, and
# detect_terminal_background installs/clears its own INT/TERM/HUP traps which
# would clobber any of ours. Every exit path here is non-fatal by design.
setup_temp_swap() {
    if [ "$NO_SWAP" = true ]; then
        log "Skipping temporary swap (--no-swap)"
        return 0
    fi
    is_low_memory || return 0

    # A previous run killed with SIGKILL (no EXIT trap fired) leaves our
    # swapfile active: adopt it so THIS run's cleanup removes it.
    if grep -q "^${SWAP_FILE}[[:space:]]" /proc/swaps 2>/dev/null; then
        warn "Temporary swapfile from a previous interrupted run is still active - reusing it"
        mark_swap_active
        return 0
    fi

    if any_swap_active; then
        log "Swap is already active - not adding a temporary swapfile"
        return 0
    fi

    # Never place swap on RAM-backed or layered roots (live ISO, containers).
    local fstype
    fstype=$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)
    case "$fstype" in
        tmpfs|ramfs|overlay|squashfs|unknown)
            warn "Root filesystem is ${fstype} - skipping temporary swap"
            return 0 ;;
    esac

    # Size to the available disk: prefer SWAP_SIZE_MIB, shrink to 1024 MiB
    # when tight, skip when even that leaves < SWAP_MIN_FREE_MIB free on /.
    local free_mib size_mib
    free_mib=$(( $(free_kib /) / 1024 ))
    size_mib="$SWAP_SIZE_MIB"
    if [ $(( free_mib - size_mib )) -lt "$SWAP_MIN_FREE_MIB" ]; then
        size_mib=1024
    fi
    if [ $(( free_mib - size_mib )) -lt "$SWAP_MIN_FREE_MIB" ]; then
        warn "Only ${free_mib} MiB free on / - skipping temporary swap"
        return 0
    fi

    if ! prompt_yes_no "Low RAM detected ($(( $(mem_total_kib) / 1024 )) MiB). Create a temporary ${size_mib} MiB swapfile at ${SWAP_FILE} for this run (removed automatically at the end)?" "Y"; then
        log "Skipping temporary swap"
        return 0
    fi

    # Stale non-active leftover (killed run + reboot): recreate from scratch
    # so size and permissions are known-good.
    if [ -e "$SWAP_FILE" ]; then
        warn "Removing stale swapfile left by a previous run"
        sudo rm -f "$SWAP_FILE"
    fi

    log "Creating ${size_mib} MiB temporary swapfile at ${SWAP_FILE}..."
    # Create + chmod 600 BEFORE writing data (no world-readable window), and
    # mark NOCOW on btrfs (the kernel rejects CoW/compressed swapfiles).
    sudo touch "$SWAP_FILE"
    sudo chmod 600 "$SWAP_FILE"
    if [ "$fstype" = "btrfs" ]; then
        sudo chattr +C "$SWAP_FILE" 2>/dev/null || true
    fi

    if ! sudo fallocate -l "${size_mib}M" "$SWAP_FILE" 2>/dev/null; then
        # fallocate unsupported on this filesystem -> dd (slower, universal)
        if ! sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size_mib" status=none; then
            warn "Could not create swapfile (disk full?) - continuing without swap"
            sudo rm -f "$SWAP_FILE" 2>/dev/null || true
            return 0
        fi
    fi

    if sudo mkswap "$SWAP_FILE" > /dev/null && sudo swapon "$SWAP_FILE"; then
        mark_swap_active
        return 0
    fi

    # swapon can reject a fallocate'd file ("holes") on some filesystems:
    # rewrite it with dd once, then give up non-fatally.
    warn "swapon failed - retrying with a dd-written swapfile..."
    sudo rm -f "$SWAP_FILE"
    sudo touch "$SWAP_FILE"
    sudo chmod 600 "$SWAP_FILE"
    if sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size_mib" status=none \
        && sudo mkswap "$SWAP_FILE" > /dev/null && sudo swapon "$SWAP_FILE"; then
        mark_swap_active
    else
        warn "Could not enable a temporary swapfile - continuing without swap"
        sudo rm -f "$SWAP_FILE" 2>/dev/null || true
    fi
    return 0
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
        # Non-fatal: a network drop between the fetch above and this pull (or
        # local commits making --ff-only refuse) must not abort a fresh-VM
        # provisioning run; --ff-only leaves the tree untouched on failure.
        if git pull --ff-only; then
            log "Re-executing updated script..."
            exec "$0" "${ORIGINAL_ARGS[@]}" || error "Failed to re-execute updated script"
        else
            warn "Self-update failed (network or git error) - continuing with current version v${VERSION}"
        fi
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

# Low-RAM / low-disk accommodations. Placed here deliberately: AFTER the
# Phase 0 self-update (EXIT traps do not survive its exec) and BEFORE the
# first heavy apt work, so the swap protects the dist-upgrade onward.
check_disk_space
setup_temp_swap
if is_low_memory; then
    # Cap build parallelism: cargo/go builds are the main OOM killers on 1 GB
    # VMs even with swap. Composes with any inherited GOFLAGS; the hardened
    # GOPROXY/GOSUMDB exports in install_go_tool are separate vars, untouched.
    export CARGO_BUILD_JOBS=1
    export GOFLAGS="${GOFLAGS:+$GOFLAGS }-p=1"
    log "Low RAM: capping build parallelism (CARGO_BUILD_JOBS=1, GOFLAGS += -p=1)"
fi

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

# Install Rust - either from repo (if >= RUSTC_MIN) or via rustup. Rust is
# always installed as a dev runtime; sd/delta still prefer apt when it ships a
# recent-enough build (see install_cargo_tool below) and only fall back to
# compiling via cargo.
if ! command -v cargo &> /dev/null; then
    log "Checking Rust version in repositories..."
    REPO_RUST_VERSION_NUM=$(apt_candidate_version_num rustc)
    if [ "$REPO_RUST_VERSION_NUM" -ge "$RUSTC_MIN" ]; then
        log "Installing Rust from repositories (candidate numeric: $REPO_RUST_VERSION_NUM, minimum: $RUSTC_MIN)..."
        apt_get install -y cargo rustc
    else
        log "Repository Rust too old or absent (numeric: $REPO_RUST_VERSION_NUM, minimum: $RUSTC_MIN), installing via rustup..."
        install_rust_via_rustup
    fi
elif command -v rustup &> /dev/null; then
    log "Updating Rust via rustup..."
    rustup update stable
else
    INSTALLED_RUST_VERSION=$(rustc --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' | head -1 || true)
    INSTALLED_RUST_VERSION_NUM=$(version_to_num "$INSTALLED_RUST_VERSION")
    log "Installed Rust version: ${INSTALLED_RUST_VERSION:-unknown} (numeric: $INSTALLED_RUST_VERSION_NUM, minimum required: $RUSTC_MIN)"
    if [ "$INSTALLED_RUST_VERSION_NUM" -lt "$RUSTC_MIN" ]; then
        log "Installed Rust is below required $RUSTC_MIN, installing rustup for a newer toolchain..."
        install_rust_via_rustup
    else
        log "Rust is already installed (apt-managed, updated via dist-upgrade)"
    fi
fi

# Install Bun (JavaScript/TypeScript runtime, package manager, drop-in Node.js replacement)
log "Installing Bun..."
if ! command -v bun &> /dev/null; then
    # Installer fetched to a file first so a truncated transfer can't execute.
    BUN_INSTALLER=$(mktemp)
    fetch_url -o "$BUN_INSTALLER" https://bun.com/install
    bash "$BUN_INSTALLER"
    rm -f "$BUN_INSTALLER"

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
if want_hacking_tools; then
    log "Installing hacking tools..."
    apt_get install -y massdns mitmproxy || true
else
    warn "Skipping hacking tools installation"
fi

# Install pipx (Python application installer)
install_apt_package "pipx" "pipx"

# Install uv (modern Python package installer)
# `pipx upgrade` also re-links ~/.local/bin/uv, so it repairs a venv whose app
# binaries were never linked (a run killed mid-install on a low-RAM VM), and it
# fails fast when uv isn't installed at all - leaving the fallback to do the
# first install. A plain `pipx install` does neither: it no-ops with exit 0
# whenever the venv exists, so a half-installed uv stayed broken on every re-run.
PIPX_DATA_DIR="${PIPX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pipx}"
# True if the uv at path $1 is pipx's (a symlink resolving into a pipx venvs
# dir). A foreign uv (standalone installer, cargo, distro package) resolves
# elsewhere and is kept as-is: `pipx install --force` would delete an
# installer's binary at ~/.local/bin/uv and replace it with pipx's own symlink.
uv_is_pipx_managed() {
    case "$(readlink -f "$1")" in
        "$PIPX_DATA_DIR"/venvs/*|"$HOME/.local/pipx/venvs/"*) return 0 ;;
    esac
    return 1
}
log "Installing/updating uv..."
export PATH=$HOME/.local/bin:$PATH
uv_path=$(command -v uv || true)
if [ -n "$uv_path" ] && ! uv_is_pipx_managed "$uv_path"; then
    log "Existing non-pipx uv found at $uv_path - keeping it"
    uv self update 2>/dev/null || true  # standalone builds only; no-ops elsewhere
elif ! { pipx upgrade uv 2>/dev/null || pipx install --force uv; }; then
    # Every pipx operation runs through its shared pip venv (.../pipx/shared).
    # An in-place python upgrade (or an interrupted run) leaves it invalid, and
    # pipx's own recovery - `python -m venv --clear` on the corpse - can itself
    # fail (pypa/pipx#294; seen as ENOTEMPTY on a DO droplet), wedging every
    # pipx command. The dir is a cache: safe to delete, rebuilt on the next
    # pipx call - the fix recommended in that issue. Wipe it (platformdirs and
    # legacy pipx <= 1.1 locations), retry once, and record a persistent
    # failure in the end-of-run summary instead of aborting the whole run.
    warn "pipx failed - resetting pipx's shared venv and retrying..."
    for d in "$PIPX_DATA_DIR/shared" "$HOME/.local/pipx/shared"; do
        chmod -R u+rwX "$d" 2>/dev/null || true  # perm-broken trees defeat rm -rf otherwise
        rm -rf "$d" 2>/dev/null || true
    done
    { pipx upgrade uv 2>/dev/null || pipx install --force uv; } || note_build_failure "uv"
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

    # Add Docker's official GPG key (world-readable so apt can use it; a fetch
    # failure stays fatal - Docker is a core install)
    sudo install -m 0755 -d /etc/apt/keyrings
    fetch_install --sudo --mode 644 "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" /etc/apt/keyrings/docker.asc

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
    sudo systemctl enable --now docker || true

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

# Render the full .zshrc to a temp file; install_user_config below compares it
# against any existing ~/.zshrc and only prompts/backs up when content differs.
ZSHRC_TMP=$(mktemp)
cat > "$ZSHRC_TMP" << 'EOF'
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

# Cache a tool's init output in a file and source it, so startup never forks
# the tool itself: the generator command runs only when the cache is missing,
# empty, or older than one of its deps (binary path, rc file - nonexistent
# deps are ignored). $commands[x] gives a fork-free binary path for deps.
# Used for dircolors, zoxide, and fzf below.
# Usage: _cached_init <cache-file-name> <generator-cmd-string> <dep>...
_cached_init() {
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/$1" gen="$2" d regen=
  shift 2
  [[ -s $cache ]] || regen=1
  for d in "$@"; do [[ -e $d && $d -nt $cache ]] && regen=1; done
  if [[ -n $regen ]]; then
    mkdir -p "${cache:h}"
    eval "$gen" > "$cache"
  fi
  [[ -s $cache ]] && source "$cache"
}

# enable color support of ls, less and man, and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    # Cached dircolors output - regenerates only after a dircolors upgrade or
    # when a custom ~/.dircolors changes; no dircolors fork on normal startups.
    _cached_init dircolors.zsh 'if [[ -r ~/.dircolors ]]; then dircolors -b ~/.dircolors; else dircolors -b; fi' $commands[dircolors] ~/.dircolors
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
# Init output cached via _cached_init - regenerates only after a zoxide upgrade.
if (( $+commands[zoxide] )) && [[ -o interactive ]]; then
    _cached_init zoxide-init.zsh 'zoxide init zsh --cmd cd' $commands[zoxide]
fi

# fzf - fuzzy finder key bindings + completion (interactive shells only).
# Ctrl-T inserts file paths, Alt-C cds into a subdir, **<Tab> triggers fuzzy
# completion. Ctrl-R is left to the hstr block below (it runs after this one and
# rebinds Ctrl-R when hstr is present); without hstr, fzf's own Ctrl-R stays.
# Init output cached via _cached_init - regenerates only after an fzf upgrade.
if (( $+commands[fzf] )) && [[ -o interactive ]]; then
    if (( $+commands[fdfind] )); then
        export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --strip-cwd-prefix --exclude .git'
        export FZF_ALT_C_COMMAND='fdfind --type d --hidden --strip-cwd-prefix --exclude .git'
    fi
    export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'
    (( $+commands[batcat] )) && export FZF_CTRL_T_OPTS='--preview "batcat --color=always --line-range :200 {}"'
    export FZF_ALT_C_OPTS='--preview "tree -C {} 2>/dev/null | head -200"'

    # fzf >= 0.48 embeds the scripts (fzf --zsh); older Debian/Kali packages
    # ship them under /usr/share/doc instead. A total failure leaves an empty
    # cache, which degrades to no key bindings (and a retry next startup).
    _cached_init fzf-init.zsh 'fzf --zsh 2>/dev/null || cat /usr/share/doc/fzf/examples/key-bindings.zsh 2>/dev/null' $commands[fzf]
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
        emulate -L zsh -o extendedglob
        local args="" buf tmp cmd

        if [[ -n "$ZSH_UP_UNSAFE_FULL_THROTTLE" ]]; then
            args="--unsafe-full-throttle"
        fi

        # Trim trailing whitespace and pipe characters (fork-free, like
        # bracketed-paste above)
        buf="${BUFFER%%[ |]#}"

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
# terminal background is dark, drop BAT_THEME from the rendered config so bat
# uses its dark default. Only act on a positive dark detection (see
# is_dark_terminal).
if is_dark_terminal; then
    sed -i '/^[[:space:]]*export BAT_THEME=/d' "$ZSHRC_TMP"
    log "Dark terminal detected: removed bat's light theme (Coldark-Cold)"
fi

install_user_config "$ZSHRC_TMP" ~/.zshrc "Overwrite existing .zshrc (strongly recommended on first run!)?" "Y"

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
        if python3 -c '
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
' < ~/.bash_history >> ~/.zsh_history 2>/dev/null; then
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
log "Configuring PowerShell profile..."
mkdir -p "$HOME/.config/powershell"

# Render the profile (base + optional light theme) to a temp file;
# install_user_config below compares it against any existing profile and only
# prompts/backs up when the content differs.
PWSH_TMP=$(mktemp)

# Base quality-of-life settings (always written).
cat > "$PWSH_TMP" << 'PWSHEOF'
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
    cat >> "$PWSH_TMP" << 'PWSHEOF'

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

install_user_config "$PWSH_TMP" "$PWSH_PROFILE" "Overwrite existing PowerShell profile?" "N"

# Configure Terminator
if has_desktop_environment; then
    log "Configuring Terminator..."
    mkdir -p ~/.config/terminator

    # Render the config to a temp file; install_user_config below compares it
    # against any existing config and only prompts/backs up when it differs.
    TERMINATOR_TMP=$(mktemp)
cat > "$TERMINATOR_TMP" << 'EOF'
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
    install_user_config "$TERMINATOR_TMP" ~/.config/terminator/config "Overwrite existing Terminator config?" "N"

    # Install Terminator tab numbers plugin
    log "Installing Terminator tab numbers plugin..."
    mkdir -p ~/.config/terminator/plugins

    if [[ ! -f ~/.config/terminator/plugins/tab_numbers.py ]]; then
        if fetch_install --mode 644 https://raw.githubusercontent.com/c0ffee0wl/terminator-tab-numbers-plugin/main/tab_numbers.py ~/.config/terminator/plugins/tab_numbers.py; then
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
# Render the config to a temp file; install_user_config below compares it
# against any existing ~/.tmux.conf and only prompts/backs up when it differs.
TMUX_TMP=$(mktemp)
cat > "$TMUX_TMP" << 'EOF'
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
install_user_config "$TMUX_TMP" ~/.tmux.conf "Overwrite existing tmux config?" "N"

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
[ -x /usr/local/bin/up ] || sudo cp "$HOME/go/bin/up" /usr/local/bin/ 2>/dev/null || true

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
install_go_tool "eget" "github.com/zyedidia/eget@latest"

# yq and lazygit: prefer a recent apt package, else build with 'go install'
# (needs Go >= GO_MIN). yq's apt package is 'yq-go' (binary yq-go); we symlink 'yq'.
install_go_tool_apt "yq"      "yq-go"   "$YQ_MIN"      "github.com/mikefarah/yq/v4@latest"       "yq-go"   "$GO_MIN"
install_go_tool_apt "lazygit" "lazygit" "$LAZYGIT_MIN" "github.com/jesseduffield/lazygit@latest" "lazygit" "$GO_MIN"

# lazydocker and gitsnip are not packaged in Debian/Ubuntu/Kali - always build
# (the min-Go gate lives in install_go_tool)
install_go_tool "lazydocker" "github.com/jesseduffield/lazydocker@latest" update "$GO_MIN"
install_go_tool "gitsnip" "github.com/dagimg-dot/gitsnip/cmd/gitsnip@latest" update "$GO_MIN"


# Install zoxide: prefer a recent apt package (Kali/sid ship 0.9.x), else the
# official installer (prebuilt binary into ~/.local/bin, first on PATH; the
# script is fetched to a file so a truncated transfer can't execute). apt is
# preferred because the installer's unauthenticated GitHub API call rate-limits
# per IP and then fails with a misleading "not packaged for your arch" error.
if apt_meets_min "zoxide" "$ZOXIDE_MIN"; then
    install_apt_package "zoxide" "zoxide"
    # Install succeeded (apt failures are fatal) - drop stale installer-placed
    # and source-built copies so the apt binary wins on PATH
    rm -f "$HOME/.local/bin/zoxide"
    remove_source_builds "zoxide"
else
    log "Installing/updating zoxide via official install script..."
    ZOXIDE_INSTALLER=$(mktemp)
    # Non-fatal: a failed download/install records zoxide and continues (the
    # .zshrc guards 'zoxide init' with $+commands[zoxide]). Stale ~/.cargo/bin
    # copies from old runs are removed only AFTER a successful install - they
    # may be the only working zoxide when the installer fails (see above).
    if fetch_url -o "$ZOXIDE_INSTALLER" \
        https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \
        && sh "$ZOXIDE_INSTALLER" --bin-dir "$HOME/.local/bin"; then
        remove_source_builds "zoxide"
    else
        note_build_failure "zoxide"
    fi
    rm -f "$ZOXIDE_INSTALLER"
fi

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

if want_hacking_tools; then

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

# ---------------------------------------------------------------------------
# upgrade-to-kali helper (Debian 12+ only)
# Installs, but never auto-runs, a converter that rebases Debian onto Kali.
# The user invokes it deliberately with: sudo upgrade-to-kali
# ---------------------------------------------------------------------------
install_upgrade_to_kali() {
    # Gate: Debian-proper only (ID=debian excludes Kali, Ubuntu, and their
    # derivatives) with VERSION_ID >= 12; an empty or non-numeric VERSION_ID
    # (testing/sid) is treated as newer. Sourcing os-release matches the rest
    # of this script (is_ubuntu, the Docker/PowerShell blocks); declaring the
    # variables local keeps its assignments out of the global scope.
    local ID VERSION_ID major
    . /etc/os-release 2>/dev/null || true
    [ "$ID" = "debian" ] || return 0
    major="${VERSION_ID%%.*}"
    if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -lt 12 ]; then
        return 0
    fi

    local dest="/usr/local/bin/upgrade-to-kali"
    write_config_file --sudo --mode 0755 "$dest" << 'UPGRADE_TO_KALI_EOF'
#!/bin/bash
# upgrade-to-kali - Convert a Debian 12+ (bookworm or newer) system into Kali Linux.
# Installed by linux-setup.sh. Run: sudo upgrade-to-kali
#
# WARNING: performs an effectively irreversible base-system rebase onto
# kali-rolling. Snapshot / back up first.
#   https://www.kali.org/docs/general-use/kali-apt-sources/
set -eo pipefail

# Deterministic English command output regardless of host locale (os-release /
# apt strings are parsed). C.UTF-8 is built into glibc (no locale-gen needed).
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

VERSION="1.6.0"

# Overridable paths/thresholds: production defaults; overridden by tests, or by
# an operator to steer detection (e.g. ESP_PATH when auto-detection misfires).
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
APT_DIR="${APT_DIR:-/etc/apt}"
BACKUP_DIR="${BACKUP_DIR:-$APT_DIR/upgrade-to-kali-backup}"
KEYRING_PATH="${KEYRING_PATH:-/usr/share/keyrings/kali-archive-keyring.gpg}"
KEYRING_URL="${KEYRING_URL:-https://archive.kali.org/archive-keyring.gpg}"
# An explicitly pinned mirror must never be overridden by the automatic
# CDN failover in run_step_with_recovery - record the pin before defaulting.
KALI_MIRROR_PINNED=false
[ -n "${KALI_MIRROR:-}" ] && KALI_MIRROR_PINNED=true
KALI_MIRROR="${KALI_MIRROR:-http://http.kali.org/kali}"
# Failover target when the configured mirror keeps failing: Kali's official
# Cloudflare-backed CDN mirror, the Kali devs' documented fallback advice.
KALI_FALLBACK_MIRROR="${KALI_FALLBACK_MIRROR:-https://kali.download/kali}"
NET_RETRIES="${NET_RETRIES:-2}"           # delayed retries per mirror/network failure
NET_RETRY_DELAY="${NET_RETRY_DELAY:-20}"  # seconds before the first retry (then doubled)
BOOT_DIR="${BOOT_DIR:-/boot}"
ESP_PATH="${ESP_PATH:-}"
MACHINE_ID_FILE="${MACHINE_ID_FILE:-/etc/machine-id}"
ENTRY_TOKEN_FILE="${ENTRY_TOKEN_FILE:-/etc/kernel/entry-token}"
INITRAMFS_CONF_DIR="${INITRAMFS_CONF_DIR:-/etc/initramfs-tools/conf.d}"
MODULES_CONF="${MODULES_CONF:-$INITRAMFS_CONF_DIR/upgrade-to-kali-modules.conf}"
STATE_FILE="${STATE_FILE:-/var/lib/upgrade-to-kali/state}"
ROOT_MIN_FREE_KIB="${ROOT_MIN_FREE_KIB:-6291456}"    # 6 GiB, warn-only
ESP_FLOOR_MOST_KIB="${ESP_FLOOR_MOST_KIB:-307200}"   # 300 MiB (Debian trixie guidance)
ESP_FLOOR_DEP_KIB="${ESP_FLOOR_DEP_KIB:-65536}"      # 64 MiB: below = hopeless, abort
ESP_HEADROOM_PCT="${ESP_HEADROOM_PCT:-25}"           # margin on a measured kernel pair
# First-run guess for the incoming Kali generic-kernel pair on the ESP under
# MODULES=dep + xz (~16-20 MiB vmlinuz + ~35-55 MiB initrd, plus slack). Used
# only until the conversion's own kernel exists and can be measured.
ESP_KALI_PAIR_DEP_KIB="${ESP_KALI_PAIR_DEP_KIB:-81920}"   # 80 MiB
# ESPs below this total cannot hold two Kali kernel pairs, so routine kernel
# upgrades would hit ENOSPC - the post-conversion advisory explains the fix.
ESP_SMALL_TOTAL_KIB="${ESP_SMALL_TOTAL_KIB:-163840}"      # 160 MiB (2x pair)
# Empty means auto-select at conversion time: kali-linux-default when a desktop
# is present, else kali-linux-headless. Set the env var to force a choice.
KALI_METAPACKAGE="${KALI_METAPACKAGE:-}"
ASSUME_YES=false
RESUME=false
SKIP_PREFLIGHT=false
RECOVERY_KIND=""   # cause of the final wrapped-step failure: ""/esp/network/unknown
STEP_LOG=""        # captured output of the last failed step (path printed by on_exit)
FORCE_IPV4=false   # set when a failure log shows IPv6 'Network is unreachable'
MIRROR_FAILED_OVER=false  # sources switched to KALI_FALLBACK_MIRROR mid-run

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'; C_NC='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_NC=''
fi
log()  { printf '%b\n' "${C_BLUE}[*]${C_NC} $*"; }
ok()   { printf '%b\n' "${C_GREEN}[+]${C_NC} $*"; }
warn() { printf '%b\n' "${C_YELLOW}[!]${C_NC} $*" >&2; }
err()  { printf '%b\n' "${C_RED}[x]${C_NC} $*" >&2; exit 1; }

usage() {
    cat << USAGE
upgrade-to-kali v${VERSION}
Convert a Debian 12+ (bookworm or newer) system into Kali Linux.

Usage: sudo upgrade-to-kali [OPTIONS]

Options:
  -y, --yes, --force   Skip the confirmation prompt (non-interactive).
  --skip-preflight     Skip the disk-space preflight checks.
  -h, --help           Show this help and exit.

This adds the Kali repository, DISABLES the Debian sources, runs a full
system upgrade against kali-rolling, and installs a Kali metapackage
(kali-linux-default when a desktop is present, else kali-linux-headless).
The base-system rebase is effectively irreversible - snapshot/back up first.

Before converting, a preflight checks free disk space. On systemd-boot
systems the kernel and full initrd are copied onto the EFI System Partition,
and Kali initrds are much larger than Debian's - a hopelessly small ESP
aborts the run. To make room the tool offers to remove stale or duplicate
boot files and surplus old kernels (never the running or the newest one),
and on virtual machines to write a persistent MODULES=dep + xz initramfs
config (revert instructions inside the written file) so the initrds shrink
enough to fit. If the kernel copy still hits ENOSPC mid-upgrade, the tool
cleans the ESP, then frees only as much space as needed (surplus kernels
first, smaller initrds second) and retries once on its own.

A failure that instead looks like a mirror/network problem (unreachable or
half-synced mirror, broken IPv6 routing) gets delayed retries: the package
lists are refreshed in between, IPv4 is forced when IPv6 is the culprit,
and the last retry switches to the kali.download CDN mirror (unless
KALI_MIRROR is set). Cached packages are kept, so retries and re-runs only
fetch what is still missing.

If a conversion is interrupted anyway, a marker is left at ${STATE_FILE} and
re-running 'sudo upgrade-to-kali' repairs dpkg and resumes the conversion.
Without a terminal on stdin, --yes is required.
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes|--force) ASSUME_YES=true ;;
            --skip-preflight) SKIP_PREFLIGHT=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage; err "Unknown option: $1" ;;
        esac
        shift
    done
}

# Read key $2 from key=value file $1 (empty when absent/unreadable).
kv_get() {
    [ -r "$1" ] || return 0
    grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Read KEY from an os-release-format file: kv_get plus quote-stripping.
osr() {
    local l
    l=$(kv_get "$OS_RELEASE_FILE" "$1")
    l="${l%\"}"; l="${l#\"}"
    printf '%s' "$l"
}

# True when dpkg has no half-installed/unconfigured packages (apt is usable).
dpkg_consistent() { [ -z "$(dpkg --audit 2>/dev/null)" ]; }

check_already_kali() {
    if [ "$(osr ID || true)" = "kali" ]; then
        ok "System already reports as Kali Linux ($(osr PRETTY_NAME || true)). Nothing to do."
        exit 0
    fi
}

check_supported_distro() {
    local id id_like ver major
    id="$(osr ID || true)"
    id_like="$(osr ID_LIKE || true)"
    ver="$(osr VERSION_ID || true)"
    if [ "$id" != "debian" ] && ! printf '%s' "$id_like" | grep -qw debian; then
        err "This tool only supports Debian (detected ID='$id' ID_LIKE='$id_like')."
    fi
    if [ "$id" = "ubuntu" ] || printf '%s' "$id_like" | grep -qw ubuntu; then
        err "Ubuntu is not supported. Kali requires a Debian base."
    fi
    major="${ver%%.*}"
    if [[ "$major" =~ ^[0-9]+$ ]]; then
        if [ "$major" -lt 12 ]; then
            err "Debian $ver detected; this tool requires Debian 12 (bookworm) or newer."
        elif [ "$major" -eq 12 ]; then
            warn "Debian 12 (bookworm) detected: rebasing to kali-rolling skips a Debian"
            warn "release, so it is a larger jump than from 13. Back up first and expect a longer run."
        fi
    fi
}

confirm() {
    $ASSUME_YES && return 0
    if $RESUME; then
        warn "This will RESUME the interrupted conversion to Kali (marker: $STATE_FILE)."
    else
        warn "This will REBASE this system onto Kali Linux (kali-rolling)."
    fi
    warn "It disables the Debian repositories and upgrades every base package."
    warn "This is effectively IRREVERSIBLE. Make a snapshot/backup first."
    printf 'Type YES to proceed: '
    local r
    read -r r || err "No input available (non-interactive?). Re-run with --yes."
    [ "$r" = "YES" ] || err "Aborted by user."
}

# Small yes/no prompt for individual remediation steps; auto-yes under --yes.
ask_yn() {
    if $ASSUME_YES; then log "$1 -> yes (--yes)"; return 0; fi
    local r
    printf '%s [Y/n] ' "$1"
    read -r r || return 1   # EOF = no
    [ -z "$r" ] || [ "$r" = "y" ] || [ "$r" = "Y" ]
}

# Default-No variant for risky removals; deliberately NOT auto-answered by
# --yes (a wrong yes could delete another OS's boot files).
ask_yn_no() {
    local r
    printf '%s [y/N] ' "$1"
    read -r r || return 1
    [ "$r" = "y" ] || [ "$r" = "Y" ]
}

# Non-interactive apt-get: lock-wait + safe conffile handling + bounded
# download retries (a full-upgrade fetches hundreds of packages - one
# transient mirror hiccup must not abort the conversion).
apt_ni() {
    local extra=()
    $FORCE_IPV4 && extra=(-o Acquire::ForceIPv4=true)
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
        -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        "${extra[@]}" "$@"
}

# Timestamped copies go to $BACKUP_DIR - outside sources.list.d, so apt does
# not print "N: Ignoring file ..." notices about them.
backup_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").backup.$(date +'%Y-%m-%d_%H-%M-%S')"
}

# Move backup/disabled artifacts a v1.0.x run left inside sources.list.d into
# $BACKUP_DIR - they make apt print "N: Ignoring file ..." notices on every
# apt invocation. Called from main so already-converted systems (where the
# litter actually lives) get cleaned too.
sweep_legacy_backups() {
    local litter
    litter=$(find "$APT_DIR/sources.list.d" -maxdepth 1 -type f \
        \( -name '*.backup.*' -o -name '*.disabled-by-upgrade-to-kali' \) 2>/dev/null || true)
    [ -n "$litter" ] || return 0
    mkdir -p "$BACKUP_DIR"
    printf '%s\n' "$litter" | xargs -d '\n' mv -t "$BACKUP_DIR"
    log "Moved old upgrade-to-kali backup files to $BACKUP_DIR (silences apt notices)"
}

# --- Disk-space preflight ---------------------------------------------------
# On systemd-boot systems kernel-install copies the kernel AND the full initrd
# onto the EFI System Partition, and Kali's MODULES=most initrds (~200 MB) are
# far larger than Debian's - on the small ESPs of cloud images (e.g.
# DigitalOcean) the copy fails mid-upgrade and leaves dpkg half-configured.
# Detect that layout, make room (stale-copy cleanup, MODULES=dep on VMs), or
# abort with guidance BEFORE anything irreversible happens.

# A missing systemd-detect-virt (rc 127) counts as "not a VM" - conservative,
# since the MODULES=dep remediation is only safe when hardware cannot change.
is_vm() {
    systemd-detect-virt --vm --quiet 2>/dev/null
}

# kernel-install entry token: explicit token file first (doubles as the test
# override), then kernel-install's own resolution - the authoritative source,
# covering install.conf ENTRY_TOKEN= and os-release IMAGE_ID/ID modes
# (systemd 251+, so present on Debian 12) - then the machine id. Same
# tool-first layering as find_esp's bootctl call. Memoized in _ENTRY_TOKEN:
# several callers (including per-item removal loops) need it, it cannot change
# mid-run, and the kernel-install exec is the expensive step.
entry_token() {
    if [ -z "${_ENTRY_TOKEN+x}" ]; then
        if [ -s "$ENTRY_TOKEN_FILE" ]; then
            _ENTRY_TOKEN=$(cat "$ENTRY_TOKEN_FILE")
        else
            _ENTRY_TOKEN=$(kernel-install --print-entry-token 2>/dev/null) || _ENTRY_TOKEN=""
            if [ -z "$_ENTRY_TOKEN" ] && [ -s "$MACHINE_ID_FILE" ]; then
                _ENTRY_TOKEN=$(cat "$MACHINE_ID_FILE")
            fi
        fi
    fi
    printf '%s' "$_ENTRY_TOKEN"
}

# Print the ESP mountpoint, or nothing when there is none (BIOS boot).
# Fallback order mirrors kernel-install's $BOOT search; autofs is accepted
# because newer Debian automounts the ESP (the later path accesses in
# kernels_on_esp/clean_stale_esp_copies trigger the mount before df runs).
find_esp() {
    if [ -n "$ESP_PATH" ]; then printf '%s' "$ESP_PATH"; return 0; fi
    local p d t
    p=$(bootctl --print-esp-path 2>/dev/null || true)   # absent bootctl -> empty
    if [ -z "$p" ]; then
        for d in /efi /boot /boot/efi; do
            t=$(findmnt -n -o FSTYPE "$d" 2>/dev/null || true)
            case "$t" in vfat|autofs) p="$d"; break ;; esac
        done
    fi
    printf '%s' "$p"
}

# True when kernel-install copies kernels+initrds onto the ESP ($1).
# Version dirs hold `linux`/`initrd` (upstream kernel-install naming) or
# `vmlinuz-<ver>`/`initrd.img-<ver>` (Debian's systemd-boot hook naming) -
# keep the naming variants in sync across all four sites that encode them:
# kernels_on_esp, esp_token_dirs, esp_copy_intact, clean_stale_esp_copies.
kernels_on_esp() {
    local esp="$1" token
    token=$(entry_token)
    if [ -n "$token" ]; then
        if compgen -G "$esp/$token/*/linux" > /dev/null || \
           compgen -G "$esp/$token/*/vmlinuz-*" > /dev/null; then return 0; fi
    fi
    if compgen -G "$esp/loader/entries/*.conf" > /dev/null; then return 0; fi
    # Debian's systemd-boot package hooks: the exact mechanism that copies
    # kernels/initrds during dpkg configure, even while the ESP is still empty.
    [ -e /etc/kernel/postinst.d/zz-systemd-boot ] && return 0
    [ -e /etc/initramfs/post-update.d/systemd-boot ] && return 0
    return 1
}

# Top-level ESP dirs holding BLS kernel copies (the current entry token,
# former machine-ids, other installs sharing the ESP), one per line. Detected
# by content - version subdirs with a kernel (`linux`/`vmlinuz-*`) or an
# initrd (a mid-copy ENOSPC can leave a version dir holding only a truncated
# initrd) - so EFI/ and loader/ are naturally excluded. Naming variants
# shared with kernels_on_esp (all four sites listed there - keep in sync).
esp_token_dirs() {
    local esp="$1" d
    for d in "$esp"/*/; do
        [ -d "$d" ] || continue
        if compgen -G "${d}*/linux" > /dev/null || \
           compgen -G "${d}*/vmlinuz-*" > /dev/null || \
           compgen -G "${d}*/initrd*" > /dev/null; then
            printf '%s\n' "${d%/}"
        fi
    done
}

# True when any candidate file ($2..) exists with the same size as $1.
any_size_match() {
    local src="$1" want f
    shift
    [ -f "$src" ] || return 1
    want=$(stat -c %s "$src")
    for f in "$@"; do
        if [ -f "$f" ] && [ "$(stat -c %s "$f")" = "$want" ]; then return 0; fi
    done
    return 1
}

# True when $esp/$2/$3 holds a complete copy of local kernel version $3:
# kernel and initrd both present (either naming variant) and sizes matching
# the /boot sources. Naming variants shared with kernels_on_esp (all four
# sites listed there - keep in sync).
esp_copy_intact() {
    local d="$1/$2/$3"
    any_size_match "$BOOT_DIR/vmlinuz-$3" "$d/linux" "$d/vmlinuz-$3" && \
        any_size_match "$BOOT_DIR/initrd.img-$3" "$d"/initrd*
}

free_kib() {
    df -Pk "$1" | awk 'NR==2 {print $4}'
}

total_kib() {
    df -Pk "$1" | awk 'NR==2 {print $2}'
}

# Largest du -k of the given files; 0 when none exist.
max_file_kib() {
    local m=0 f s
    for f in "$@"; do
        [ -f "$f" ] || continue
        s=$(du -k "$f" | cut -f1)
        if [ "$s" -gt "$m" ]; then m=$s; fi
    done
    printf '%s' "$m"
}

# All kernel versions present in /boot, one per line.
boot_kernel_versions() {
    local f
    for f in "$BOOT_DIR"/vmlinuz-*; do
        [ -f "$f" ] || continue
        printf '%s\n' "${f##*/vmlinuz-}"
    done
}

newest_boot_kernel() {
    local newest="" v
    while IFS= read -r v; do
        if [ -z "$newest" ] || dpkg --compare-versions "$v" gt "$newest"; then newest="$v"; fi
    done < <(boot_kernel_versions)
    printf '%s' "$newest"
}

# All /boot kernel versions except the newest, one per line.
nonnewest_boot_kernels() {
    local newest v
    newest=$(newest_boot_kernel)
    while IFS= read -r v; do
        if [ "$v" != "$newest" ]; then printf '%s\n' "$v"; fi
    done < <(boot_kernel_versions)
}

# The conversion-installed kernel: any /boot version newer than the baseline
# recorded in the state marker (empty before the marker exists or before the
# upgrade installs one). Vendor naming is deliberately not used - Kali kernel
# ABIs lacked a "kali" substring for the whole 6.6 era.
conversion_kernel() {
    local baseline newest
    baseline=$(kv_get "$STATE_FILE" baseline_kernel)
    newest=$(newest_boot_kernel)
    [ -n "$baseline" ] && [ -n "$newest" ] || return 0
    if dpkg --compare-versions "$newest" gt "$baseline"; then printf '%s' "$newest"; fi
    return 0
}

# KiB of one kernel version's ($1) /boot pair: vmlinuz plus (largest) initrd.
pair_kib() {
    printf '%s' $(( $(max_file_kib "$BOOT_DIR/vmlinuz-$1") + $(max_file_kib "$BOOT_DIR/initrd.img-$1"*) ))
}

# Estimated KiB the incoming Kali kernel+initrd needs on the ESP ($2).
# $1 = most|dep (the initramfs MODULES policy the estimate is for).
# Once the conversion has installed its kernel (conversion_kernel), measure:
# staged intact under the current token means nothing is left to copy (need
# 0); else its pair plus ESP_HEADROOM_PCT - ESP copies overwrite in place,
# so free space only has to absorb roughly one extra pair (a newer version
# arriving mid-upgrade). Before that there is nothing to measure, so guess
# the incoming pair itself: the local pair predicts nothing (a Debian cloud
# kernel's ~30 MB initrd vs. Kali's ~200 MB one), so the dep guess is
# ESP_KALI_PAIR_DEP_KIB and the most guess keeps 2x-the-local-pair with the
# Debian trixie release notes' "at least 300 MB free" floor. Either guess
# grows by the newest local pair when that kernel has no intact copy under
# the CURRENT entry token yet: the next hook run then ADDS a copy alongside
# the former-token one instead of overwriting in place (see
# clean_stale_esp_copies).
esp_required_kib() {
    local policy="$1" esp="$2" newest need
    newest=$(conversion_kernel)
    if [ -n "$newest" ]; then
        if esp_copy_intact "$esp" "$(entry_token)" "$newest"; then
            need=0
        else
            need=$(( $(pair_kib "$newest") * (100 + ESP_HEADROOM_PCT) / 100 ))
        fi
    else
        case "$policy" in
            dep) need="$ESP_KALI_PAIR_DEP_KIB" ;;
            *)   need=$(( ( $(max_file_kib "$BOOT_DIR"/vmlinuz-*) + $(max_file_kib "$BOOT_DIR"/initrd.img-*) ) * 2 ))
                 if [ "$need" -lt "$ESP_FLOOR_MOST_KIB" ]; then need="$ESP_FLOOR_MOST_KIB"; fi ;;
        esac
        newest=$(newest_boot_kernel)
        if [ -n "$newest" ] && ! esp_copy_intact "$esp" "$(entry_token)" "$newest"; then
            need=$(( need + $(pair_kib "$newest") ))
        fi
    fi
    printf '%s' "$need"
}

# Logs the ESP's ($1) free space vs. the measured/estimated need for
# MODULES=$2; true when it fits.
esp_fits() {
    local esp="$1" policy="$2" need free mode
    need=$(esp_required_kib "$policy" "$esp")
    free=$(free_kib "$esp")
    mode="estimated"
    if [ -n "$(conversion_kernel)" ]; then mode="measured"; fi
    log "ESP free: $((free / 1024)) MiB; $mode need (MODULES=$policy): $((need / 1024)) MiB"
    [ "$free" -ge "$need" ]
}

# The MODULES policy in effect for newly generated initrds.
effective_policy() {
    if [ -f "$MODULES_CONF" ]; then printf 'dep'; else printf 'most'; fi
}

# True when both files exist but their sizes differ (a mid-copy ENOSPC leftover).
size_mismatch() {
    [ -f "$1" ] && [ -f "$2" ] && [ "$(stat -c %s "$1")" != "$(stat -c %s "$2")" ]
}

# Remove provably-stale boot files from the ESP (prompted): version dirs for
# kernels that no longer exist locally, truncated/partial copies whose size
# differs from the /boot source (what a mid-copy ENOSPC leaves behind), and
# former-token duplicates. All token dirs are scanned, not just the current
# one: cloud images regenerate the machine id on first boot, so image-build
# copies live under a former token, invisible to a current-token-only scan
# and duplicated (not overwritten) by the first kernel-install run. A foreign
# dir is a removable duplicate only when its version already has an intact
# current-token copy - before the first regen it is the only bootable entry.
# Foreign dirs for versions unknown to this OS may belong to ANOTHER install
# sharing the ESP: separate default-No prompt, never auto-answered by --yes.
# Safe because the source of truth stays in $BOOT_DIR - dpkg configure and the
# initramfs post-update hook re-copy fresh files. Must run before measuring
# free space AND before any resume repair: dpkg --configure -a re-triggers
# the same ENOSPC otherwise. Always returns 0 (callers run bare under set -e).
clean_stale_esp_copies() {
    local esp="$1" cur tdir token verdir ver f it
    local stale=() foreign=()
    cur=$(entry_token)
    while IFS= read -r tdir; do
        token=$(basename "$tdir")
        for verdir in "$tdir"/*/; do
            [ -d "$verdir" ] || continue
            ver=$(basename "$verdir")
            if [ ! -e "$BOOT_DIR/vmlinuz-$ver" ] && [ ! -d "/lib/modules/$ver" ]; then
                # Version unknown to this OS: our orphan under the current
                # token, possibly another OS's kernel under a foreign one.
                if [ "$token" = "$cur" ]; then stale+=("$verdir"); else foreign+=("$verdir"); fi
                continue
            fi
            if [ "$token" != "$cur" ] && [ -n "$cur" ] && esp_copy_intact "$esp" "$cur" "$ver"; then
                stale+=("$verdir")   # former-token duplicate; the current-token copy wins
                continue
            fi
            for f in "$verdir"initrd*; do
                if size_mismatch "$f" "$BOOT_DIR/initrd.img-$ver"; then stale+=("$f"); fi
            done
            # Kernel copy: `linux` (upstream naming) or `vmlinuz-<ver>` (Debian
            # hook) - keep the naming variants in sync with kernels_on_esp
            # (which lists all four sites that encode them).
            for f in "$verdir"linux "$verdir"vmlinuz-*; do
                if size_mismatch "$f" "$BOOT_DIR/vmlinuz-$ver"; then stale+=("$f"); fi
            done
        done
    done < <(esp_token_dirs "$esp")
    if [ "${#stale[@]}" -gt 0 ]; then
        warn "Stale/incomplete/duplicate boot files on the ESP (safe to remove; re-copied from $BOOT_DIR):"
        printf '      %s\n' "${stale[@]}" >&2
        if ask_yn "Remove them to free ESP space?"; then
            for it in "${stale[@]}"; do
                case "$it" in
                    */) remove_esp_verdir "$it" ;;
                    *)  rm -f "$it" ;;
                esac
            done
            ok "Removed ${#stale[@]} stale ESP item(s)"
        fi
    fi
    if [ "${#foreign[@]}" -gt 0 ]; then
        if $ASSUME_YES; then
            log "Left untouched (kernels unknown to this OS, never auto-removed): ${foreign[*]}"
        else
            warn "ESP dirs whose kernels are unknown to this OS (they may belong to ANOTHER install sharing this ESP):"
            printf '      %s\n' "${foreign[@]}" >&2
            if ask_yn_no "Remove them? Only say yes if no other OS boots from this disk"; then
                for it in "${foreign[@]}"; do
                    remove_esp_verdir "$it"
                done
                ok "Removed ${#foreign[@]} foreign ESP dir(s)"
            fi
        fi
    fi
    return 0
}

# Kernel versions that are safe to drop: installed in /boot but neither the
# running kernel nor the newest one (bootctl's own eviction rule: never the
# booted entry, never the last remaining).
surplus_kernel_versions() {
    local running v
    running=$(uname -r)
    while IFS= read -r v; do
        if [ "$v" != "$running" ]; then printf '%s\n' "$v"; fi
    done < <(nonnewest_boot_kernels)
}

# Remove one version's ($3) files under one token dir ($2), plus only THAT
# token's loader entries (kernel-install names them <token>-<ver>[+tries].conf).
# Token-scoped on purpose: duplicate cleanup must not delete the current
# token's kept entry.
remove_esp_token_version() {
    local esp="$1" token="$2" ver="$3"
    rm -rf "${esp:?}/$token/$ver"
    rm -f "$esp/loader/entries/$token-$ver"*.conf
}

# remove_esp_token_version for a full version-dir path ($ESP/<token>/<ver>[/]).
remove_esp_verdir() {
    local d="${1%/}"
    remove_esp_token_version "$(dirname "$(dirname "$d")")" \
        "$(basename "$(dirname "$d")")" "$(basename "$d")"
}

# Remove a kernel version's ($2) boot files from the ESP ($1) everywhere:
# its version dir under every token dir plus any loader entry referencing it
# - mirroring what apt purge / kernel-install remove would have achieved.
remove_esp_version() {
    local esp="$1" ver="$2" tdir
    while IFS= read -r tdir; do
        remove_esp_token_version "$esp" "$(basename "$tdir")" "$ver"
    done < <(esp_token_dirs "$esp")
    rm -f "$esp"/loader/entries/*"$ver"*.conf
}

# Free a whole kernel+initrd pair per surplus kernel (prompted). With a
# healthy dpkg one batched apt purge does it cleanly (the kernel hooks remove
# the ESP copies and loader entries); mid-resume dpkg is broken and apt would
# refuse, so use the standalone canonical primitives instead:
# update-initramfs -d deregisters the version and deletes its initrd (so the
# initramfs triggers cannot re-copy it), kernel-install remove drops the ESP
# version dir and loader entry - and apt's autoremove finishes the package
# purge after the repair. Returns 0 only when kernels were actually removed,
# so callers can skip the re-measure otherwise.
remove_surplus_kernels() {
    local esp="$1" v
    local candidates=()
    mapfile -t candidates < <(surplus_kernel_versions)
    [ "${#candidates[@]}" -gt 0 ] || return 1
    warn "Kernels that are neither running nor newest are taking ESP space: ${candidates[*]}"
    ask_yn "Remove them to free ESP space (the running and the newest kernel are kept)?" || return 1
    if dpkg_consistent; then
        apt_ni purge -y "${candidates[@]/#/linux-image-}"
    else
        for v in "${candidates[@]}"; do
            update-initramfs -d -k "$v" 2>/dev/null || true
            if ! BOOT_ROOT="$esp" kernel-install remove "$v" 2>/dev/null; then
                remove_esp_version "$esp" "$v"
            fi
        done
    fi
    ok "Removed ${#candidates[@]} surplus kernel(s)"
}

# Persistent initramfs shrink policy: MODULES=dep (only this hardware's
# modules - offered on VMs only, where hardware does not change) plus
# COMPRESS=xz when available (smallest initrds; guarded because initramfs-
# tools aborts on a configured-but-missing compressor). Rewritten in full so
# older dep-only versions of the file pick up the compression on re-runs.
write_shrink_conf() {
    log "Writing $MODULES_CONF (MODULES=dep + xz compression)"
    mkdir -p "$INITRAMFS_CONF_DIR"
    cat > "$MODULES_CONF" << 'CONF'
# Written by upgrade-to-kali: MODULES=dep keeps initrds small enough for this
# system's small EFI System Partition (systemd-boot copies kernel+initrd there);
# COMPRESS=xz (when present) packs them hardest - slightly slower builds/boots.
# Safe on VMs, where the (virtual) hardware does not change.
# Revert: delete this file, then run: sudo update-initramfs -u -k all
MODULES=dep
CONF
    if command -v xz > /dev/null 2>&1; then
        printf 'COMPRESS=xz\n' >> "$MODULES_CONF"
    else
        warn "xz not found - initrds will use the default compressor (larger)"
    fi
}

# VM-only shrink remediation: prompt, write the conf, regenerate all initrds,
# then re-clean the ESP - the regen creates current-token copies, turning any
# pre-baked former-token pairs into reclaimable duplicates. $2=fatal aborts on
# a failed regen (preflight: pre-confirm, nothing converted yet); $2=tolerant
# warns and continues (recovery ladder: the retry is the verdict). True when
# the shrink was applied.
offer_shrink() {
    local esp="$1" policy="$2"
    is_vm || return 1
    warn "The ESP is too small for Kali's default (MODULES=most) initrds."
    ask_yn "Write MODULES=dep + xz to $MODULES_CONF and regenerate initrds now (VM-safe, persistent)?" || return 1
    write_shrink_conf
    log "Regenerating all initrds with the shrink policy"
    if ! update-initramfs -u -k all; then
        if [ "$policy" = fatal ]; then
            warn "update-initramfs failed - the ESP is likely still too full."
            warn "Free ESP space manually (purge old kernels, remove stale files), then re-run."
            err "Could not regenerate a smaller initrd."
        fi
        warn "update-initramfs failed (likely still ENOSPC) - continuing recovery"
    fi
    clean_stale_esp_copies "$esp"
    return 0
}

# Compact per-token-dir usage breakdown - makes failed-run logs diagnosable.
# Always returns 0 (purely informational).
log_esp_inventory() {
    local esp="$1"
    local total free
    log "ESP inventory ($esp):"
    du -sk "$esp"/*/ 2>/dev/null | awk '{printf "      %5d MiB  %s\n", $1/1024, $2}' >&2 || true
    total=$(total_kib "$esp" 2>/dev/null) || total=0
    free=$(free_kib "$esp" 2>/dev/null) || free=0
    log "      total $((${total:-0} / 1024)) MiB, free $((${free:-0} / 1024)) MiB"
    return 0
}

preflight() {
    if $SKIP_PREFLIGHT; then
        warn "Preflight checks skipped (--skip-preflight)"
        return 0
    fi
    # Root filesystem: warn only - the rebase downloads ~2 GB of archives and
    # installs several GB on top.
    local rootfree
    rootfree=$(free_kib /)
    if [ "$rootfree" -lt "$ROOT_MIN_FREE_KIB" ]; then
        warn "Low free space on /: $((rootfree / 1024)) MiB (recommended: >= $((ROOT_MIN_FREE_KIB / 1024)) MiB)."
    fi
    # ESP: fatal when kernels are copied there and room cannot be made.
    # Remediation rung order (clean -> surplus kernels -> shrink) mirrors
    # esp_recovery_ladder - keep the two in sync.
    local esp
    esp=$(find_esp)
    if [ -z "$esp" ]; then
        log "No EFI System Partition detected (BIOS boot) - ESP check skipped."
        return 0
    fi
    if ! kernels_on_esp "$esp"; then
        log "Kernels are not copied to the ESP (GRUB layout) - ESP check skipped."
        return 0
    fi
    log "systemd-boot layout detected: kernels and initrds are copied to $esp"
    log_esp_inventory "$esp"
    clean_stale_esp_copies "$esp"
    if esp_fits "$esp" most; then
        ok "ESP has enough free space."
        return 0
    fi
    if remove_surplus_kernels "$esp" && esp_fits "$esp" most; then
        ok "ESP has enough free space."
        return 0
    fi
    local free
    offer_shrink "$esp" fatal || true
    # Verdict under the dep policy when it is in effect - from this run's
    # shrink or a previous one (the conf persists across resumes, so the
    # verdict must not depend on re-answering the prompt). Tight-but-
    # plausible proceeds: the dep need is a guess about a kernel that does
    # not exist yet, and a mid-upgrade ENOSPC now recovers and retries
    # in-run - do not block a conversion that empirically succeeds on
    # ~105 MiB cloud ESPs. Below the hard floor is hopeless and aborts.
    if [ "$(effective_policy)" = dep ]; then
        if esp_fits "$esp" dep; then
            ok "ESP has enough free space with MODULES=dep."
            return 0
        fi
        free=$(free_kib "$esp")
        if [ "$free" -ge "$ESP_FLOOR_DEP_KIB" ]; then
            warn "ESP space is tight ($((free / 1024)) MiB free). Continuing anyway - if the kernel"
            warn "copy still hits ENOSPC mid-upgrade, the tool cleans up, shrinks and retries."
            return 0
        fi
    fi
    warn "The ESP ($esp) does not have enough free space for the Kali kernel+initrd."
    warn "Fix manually, then re-run one of:"
    warn "  - echo MODULES=dep > $MODULES_CONF && update-initramfs -u -k all"
    warn "    (VM-safe; on changing hardware prefer COMPRESS=xz in /etc/initramfs-tools/initramfs.conf)"
    warn "  - purge old kernels: dpkg -l 'linux-image-*', then apt-get purge <old versions>"
    warn "  - remove leftover version dirs under $esp/<machine-id>/ ('bootctl cleanup' on systemd >= 253)"
    warn "  - grow the ESP (needs repartitioning)"
    err "Aborting before any conversion step (nothing was converted)."
}

# --- Conversion state & failure guidance ------------------------------------

# Printed on any nonzero exit after the conversion has started (set -e death,
# err(), or Ctrl-C - bash runs EXIT traps on fatal signals too).
on_exit() {
    local rc=$?
    [ "$rc" -eq 0 ] && return 0
    warn "Conversion did NOT complete (exit code $rc). The system may be part-Debian, part-Kali."
    if [ -n "$STEP_LOG" ] && [ -s "$STEP_LOG" ]; then
        warn "Output of the failed step was kept at $STEP_LOG for inspection."
    fi
    case "$RECOVERY_KIND" in
        network)
            warn "The failure looked like a mirror/network problem, not a disk-space one,"
            warn "and the automatic delayed retries did not get through - check DNS,"
            warn "firewall/proxy, and general connectivity."
            $MIRROR_FAILED_OVER && warn "(The $KALI_FALLBACK_MIRROR CDN fallback was tried too.)"
            warn "Downloaded packages are cached, so re-running 'sudo upgrade-to-kali'"
            warn "resumes and only fetches what is still missing; to pin a mirror:"
            warn "    sudo KALI_MIRROR=$KALI_FALLBACK_MIRROR upgrade-to-kali"
            ;;
        esp|unknown)
            warn "An automatic ESP cleanup and retry already ran and did not suffice; if a"
            warn "re-run fails the same way, free ESP space manually first (see below)."
            ;;
    esac
    warn "Recover manually:"
    warn "  1. sudo dpkg --configure -a"
    warn "  2. sudo apt-get -f install"
    warn "  3. sudo apt-get update && sudo apt-get -y full-upgrade"
    warn "  4. sudo apt-get install -y kali-archive-keyring ${KALI_METAPACKAGE:-kali-linux-headless}"
    warn "  5. sudo apt-get -y autoremove --purge"
    warn "Or simply re-run 'sudo upgrade-to-kali': the state marker ($STATE_FILE) was kept,"
    warn "so it will repair dpkg and resume. If this failure was 'No space left on device'"
    warn "on the EFI partition, the re-run's preflight offers cleanup and a smaller initrd."
}

mark_conversion_started() {
    mkdir -p "$(dirname "$STATE_FILE")"
    {
        printf 'version=%s\n' "$VERSION"
        printf 'started=%s\n' "$(date -Is)"
        printf 'metapackage=%s\n' "$KALI_METAPACKAGE"
        # Any /boot kernel newer than this was installed by the conversion -
        # esp_required_kib measures it instead of guessing.
        printf 'baseline_kernel=%s\n' "$(newest_boot_kernel)"
    } > "$STATE_FILE"
    trap on_exit EXIT
}

finish_conversion() {
    rm -f "$STATE_FILE"
    rmdir "$(dirname "$STATE_FILE")" 2>/dev/null || true
    trap - EXIT
}

# True when no conversion work remains: the system identifies as Kali, dpkg
# is consistent, and the recorded metapackage is installed. Used on resume to
# recognize a marker whose conversion was finished out-of-band (manually, or
# by a crash after the last real step) - without this, the preflight could
# block the tool from ever converging and cleaning its own marker.
conversion_complete() {
    [ "$(osr ID || true)" = "kali" ] || return 1
    dpkg_consistent || return 1
    local mp
    mp=$(kv_get "$STATE_FILE" metapackage)
    [ -z "$mp" ] || dpkg -s "$mp" 2>/dev/null | grep -q '^Status: install ok installed'
}

# Resume: put dpkg/apt back into a consistent state before re-running the
# (idempotent) conversion steps. The explicit || return 1 keeps a dpkg
# failure fatal even when the caller runs this errexit-suppressed (the
# retry wrapper does), instead of masking it behind a passing apt -f.
repair_packages() {
    log "Repairing any half-configured packages first"
    dpkg --configure -a || return 1
    apt_ni -y -f install
}

# --- In-run ENOSPC recovery --------------------------------------------------
# A mid-upgrade "No space left on device" on the ESP wedges dpkg; previously
# the tool exited with guidance and required a manual resume run. The ladder
# below automates that field-proven recovery between two attempts of the
# failed step, so a single invocation converges even on the ~105 MiB ESPs of
# fresh cloud droplets.

# Last resort: drop every non-newest kernel's ESP copies and loader entries
# from ALL token dirs - after the ladder's surplus purge that is normally
# just the RUNNING kernel. ESP copies only, deliberately not a package
# purge: removing the running kernel's /lib/modules would make every module
# load fail (firewall, filesystems) for the rest of the conversion. The
# /boot sources stay, and the newest kernel's files land via the retried
# dpkg configure - but between eviction and that copy a crash would leave no
# bootable entry, hence the explicit warning. Only our own /boot versions
# are targeted; another OS's dirs hold different versions.
evict_nonnewest_esp_copies() {
    local esp="$1" v
    local victims=()
    mapfile -t victims < <(nonnewest_boot_kernels)
    [ "${#victims[@]}" -gt 0 ] || return 0
    warn "Last resort: remove the ESP boot files of non-newest kernel(s), usually"
    warn "including the running one: ${victims[*]}"
    warn "Their /boot sources stay and the newest kernel is copied right after - but if"
    warn "this machine crashes before that copy finishes, it cannot boot on its own."
    ask_yn "Evict them from the ESP to make room for the newest kernel?" || return 0
    for v in "${victims[@]}"; do
        remove_esp_version "$esp" "$v"
    done
    ok "Evicted ${#victims[@]} kernel version(s) from the ESP"
    return 0
}

# Best-effort remediation between the two attempts of a failed step: clean ->
# remove surplus kernels -> shrink -> evict -> repair, mirroring the manual
# recovery that resume mode is built on, cheapest and safest space first.
# The clean/surplus/shrink rung order mirrors preflight's ESP remediation -
# keep the two in sync (evict + repair are recovery-only tail rungs).
# Cleaning MUST precede the dpkg repair - configure re-triggers the ESP copy,
# and the truncated leftover otherwise re-breaks it. A fit check gates every
# mutating rung, so remediation stops as soon as there is room (need is 0
# once the newest pair landed intact, and a non-ESP failure like a mirror
# hiccup mutates nothing): the dep shrink is only offered when kernel
# removal did not suffice, and the running kernel's ESP copies stay the last
# resort. The policy is re-resolved before each check - offer_shrink may
# have just written the conf. Every rung is idempotent, prompted where it
# mutates, and guarded: the ladder never aborts the run itself; the retry
# after it is the real verdict.
esp_recovery_ladder() {
    local esp
    esp=$(find_esp)
    if [ -n "$esp" ] && kernels_on_esp "$esp"; then
        log_esp_inventory "$esp"
        clean_stale_esp_copies "$esp"
        if ! esp_fits "$esp" "$(effective_policy)"; then
            remove_surplus_kernels "$esp" || true
            if ! esp_fits "$esp" "$(effective_policy)"; then
                offer_shrink "$esp" tolerant || true
                if ! esp_fits "$esp" "$(effective_policy)"; then
                    evict_nonnewest_esp_copies "$esp"
                fi
            fi
        fi
    fi
    # Generic dpkg/apt repair - also what makes non-ESP failures retryable.
    repair_packages || true
    return 0
}

# Classify a failed step from its captured output: esp | network | unknown.
# Pure (reads only the file) so it is unit-testable via sourcing. ENOSPC is
# checked FIRST - a mixed failure (dead mirror AND full ESP) needs space,
# not patience. The network list covers dead/unreachable mirrors, DNS blips,
# and mid-sync mirrors (hash/size mismatch - the fix is the same: refresh
# lists and retry); pool-file 404s match via "Failed to fetch".
classify_step_failure() {
    if grep -qi 'No space left on device' "$1" 2>/dev/null; then
        printf 'esp\n'
    elif grep -qiE 'Unable to fetch|Failed to fetch|Cannot initiate the connection|Network is unreachable|Temporary failure resolving|Connection timed out|Connection refused|Connection reset by peer|Could not connect|Could not resolve|Error reading from server|Hash Sum mismatch|File has unexpected size|Mirror sync in progress' "$1" 2>/dev/null; then
        printf 'network\n'
    else
        printf 'unknown\n'
    fi
}

# apt tried an IPv6 address (the parenthesized address contains a colon) and
# the kernel said the network is unreachable: broken v6 routing, common on
# VMs/VPNs. Standard remedy is ForceIPv4 - safe, because an IPv6-only host
# was already failing over v4 anyway.
log_shows_broken_ipv6() {
    grep -qE 'connection to [^ ]* ?\([0-9a-fA-F:]*:[0-9a-fA-F:]*\)[^(]*\(101: Network is unreachable\)' "$1" 2>/dev/null
}

# Run a conversion step, teeing its output (still streamed) to a temp log so
# a failure can be classified and the matching recovery chosen: the ESP
# ladder for ENOSPC, delayed retries for mirror/network fetch errors (apt's
# cache means a retry only fetches what is still missing - deliberately no
# --fix-missing, a distro rebase must not proceed with missing packages),
# and the ladder + one retry for anything else (previous behavior). The
# failure is re-classified after every attempt (a network failure's retry
# can hit ENOSPC next), with hard budgets - the ladder runs at most once,
# network retries at most NET_RETRIES times. Each network retry refreshes
# the lists so the http.kali.org redirector can hand out a healthier
# mirror, forces IPv4 once broken v6 routing is seen, and the last one
# fails over to the kali.download CDN (never overriding a user-pinned
# KALI_MIRROR). When the budgets are spent the last rc is
# returned and dies under set -e at the call site; RECOVERY_KIND (set only
# then, so a recovered step never poisons a later failure's message) and
# STEP_LOG steer on_exit's guidance.
# NOTE: the step runs on the left of a pipeline, i.e. in a subshell -
# wrapped steps must not mutate globals (apt_ni/repair_packages do not).
# The wrapper body itself runs in the main shell, which is why its
# FORCE_IPV4/KALI_MIRROR mutations stick.
run_step_with_recovery() {
    local rc kind logf ladder_ran=false net_left="$NET_RETRIES" delay="$NET_RETRY_DELAY"
    logf=$(mktemp) || logf=/dev/null   # degrades to kind=unknown
    STEP_LOG="$logf"
    while :; do
        rc=0
        "$@" 2>&1 | tee "$logf" || rc=${PIPESTATUS[0]}
        if [ "$rc" -eq 0 ]; then
            [ "$logf" = /dev/null ] || rm -f "$logf"
            STEP_LOG=""
            return 0
        fi
        kind=$(classify_step_failure "$logf")
        case "$kind" in
            network)
                if [ "$net_left" -gt 0 ]; then
                    net_left=$((net_left - 1))
                    warn "Step failed (exit $rc): $* - looks like a mirror/network failure,"
                    warn "not a disk-space one. Retrying in ${delay}s (cached .debs are kept)."
                    if ! $FORCE_IPV4 && log_shows_broken_ipv6 "$logf"; then
                        FORCE_IPV4=true
                        warn "IPv6 routing looks broken - forcing IPv4 for all further apt calls"
                    fi
                    # MIRROR_FAILED_OVER is global: net_left resets per wrapped
                    # step, so a later step's failure must not redo the failover.
                    if [ "$net_left" -eq 0 ] && ! $KALI_MIRROR_PINNED && ! $MIRROR_FAILED_OVER; then
                        MIRROR_FAILED_OVER=true
                        KALI_MIRROR="$KALI_FALLBACK_MIRROR"
                        warn "Failing over to the CDN mirror $KALI_MIRROR for the last retry"
                        warn "(it stays in your sources afterwards - both are official Kali mirrors)"
                        write_kali_sources
                    fi
                    sleep "$delay"; delay=$((delay * 2))
                    apt_ni update || true
                    log "Retrying: $*"
                    continue
                fi
                ;;
            esp|unknown)
                if ! $ladder_ran; then
                    ladder_ran=true
                    warn "Step failed (exit $rc): $* - attempting ESP recovery, then one retry"
                    esp_recovery_ladder || true
                    log "Retrying: $*"
                    continue
                fi
                ;;
        esac
        RECOVERY_KIND="$kind"
        return "$rc"
    done
}

# env var > state file > desktop detection. Resolved before the marker is
# written (so the marker only pre-exists on resume) and persisted in it, so a
# resumed run converges on the same choice.
resolve_metapackage() {
    if [ -z "$KALI_METAPACKAGE" ]; then
        KALI_METAPACKAGE=$(kv_get "$STATE_FILE" metapackage)
    fi
    if [ -z "$KALI_METAPACKAGE" ]; then
        if has_desktop; then KALI_METAPACKAGE=kali-linux-default; else KALI_METAPACKAGE=kali-linux-headless; fi
    fi
    log "Target Kali metapackage: $KALI_METAPACKAGE"
}

install_keyring() {
    log "Installing Kali archive keyring -> $KEYRING_PATH"
    local tmp; tmp=$(mktemp)
    # Bounded retries (default is 20 tries): same transient-failure policy as
    # apt_ni's Acquire::Retries - one network blip must not abort the conversion.
    if ! wget -q --tries=3 --waitretry=2 --retry-connrefused -O "$tmp" "$KEYRING_URL"; then
        rm -f "$tmp"; err "Failed to download Kali keyring from $KEYRING_URL"
    fi
    install -o root -g root -m 644 "$tmp" "$KEYRING_PATH"
    rm -f "$tmp"
}

write_kali_sources() {
    local dest="$APT_DIR/sources.list.d/kali.sources"
    mkdir -p "$APT_DIR/sources.list.d"
    cat > "$dest" << SRC
# Kali Linux repository (added by upgrade-to-kali)
# https://www.kali.org/docs/general-use/kali-apt-sources/
Types: deb
URIs: ${KALI_MIRROR}
Suites: kali-rolling
Components: main contrib non-free non-free-firmware
Signed-By: ${KEYRING_PATH}
SRC
    log "Wrote Kali repository -> $dest"
}

disable_debian_sources() {
    local deb822="$APT_DIR/sources.list.d/debian.sources"
    if [ -f "$deb822" ]; then
        # The mv itself preserves the unmodified file in $BACKUP_DIR, so no
        # separate backup copy is needed (unlike sources.list below, which
        # sed mutates in place).
        mkdir -p "$BACKUP_DIR"
        mv "$deb822" "$BACKUP_DIR/debian.sources.disabled-by-upgrade-to-kali"
        log "Disabled $deb822 (moved to $BACKUP_DIR)"
    fi
    local legacy="$APT_DIR/sources.list"
    if [ -f "$legacy" ] && grep -qE '^[[:space:]]*deb(-src)?[[:space:]]' "$legacy"; then
        backup_file "$legacy"
        sed -ri 's/^([[:space:]]*)(deb(-src)?[[:space:]])/\1#\2/' "$legacy"
        log "Commented out Debian entries in $legacy"
    fi
    local other
    other=$(find "$APT_DIR/sources.list.d" -maxdepth 1 -type f \
        \( -name '*.list' -o -name '*.sources' \) ! -name 'kali.sources' 2>/dev/null || true)
    if [ -n "$other" ]; then
        warn "Other repository files remain enabled (left untouched):"
        printf '%s\n' "$other" | sed 's/^/      /' >&2
        warn "Remove/disable them if apt later reports version conflicts."
    fi
}

# True when a graphical desktop is present (mirror of linux-setup's
# has_desktop_environment - keep the package lists in sync); picks
# kali-linux-default over -headless.
has_desktop() {
    if [ -d /usr/share/xsessions ] && [ -n "$(ls -A /usr/share/xsessions 2>/dev/null)" ]; then return 0; fi
    if [ -d /usr/share/wayland-sessions ] && [ -n "$(ls -A /usr/share/wayland-sessions 2>/dev/null)" ]; then return 0; fi
    if [ -s /etc/X11/default-display-manager ]; then return 0; fi
    if dpkg -l 2>/dev/null | grep -qE '^ii[[:space:]]+(xfce4|gnome-shell|kde-plasma-desktop|plasma-desktop|lxde-core|mate-desktop-environment|cinnamon)'; then return 0; fi
    return 1
}

# Success advisory for small ESPs: two kernel pairs never fit on them, so
# the NEXT kernel ABI upgrade would hit the same mid-upgrade ENOSPC while old
# and new coexist. Guidance only - the old kernel is the only known-good
# fallback until the new one has survived a reboot. Runs after the EXIT trap
# is gone, so every command is guarded: a cosmetic failure here must not turn
# a completed conversion into a nonzero exit.
post_conversion_esp_advice() {
    local esp total v old_pkgs=""
    esp=$(find_esp)
    [ -n "$esp" ] || return 0
    kernels_on_esp "$esp" || return 0
    total=$(total_kib "$esp" 2>/dev/null) || return 0
    [ -n "$total" ] && [ "$total" -lt "$ESP_SMALL_TOTAL_KIB" ] || return 0
    while IFS= read -r v; do
        old_pkgs="$old_pkgs linux-image-$v"
    done < <(nonnewest_boot_kernels)
    warn "This ESP ($esp, $((total / 1024)) MiB) is too small to hold two kernel+initrd"
    warn "pairs, so a FUTURE kernel upgrade can hit 'No space left on device' again"
    warn "while the old and the new version coexist."
    if [ -n "$old_pkgs" ]; then
        warn "After verifying the new kernel boots (sudo reboot, then uname -r), free the"
        warn "ESP by purging the old one(s):"
        warn "    sudo apt purge -y$old_pkgs"
    fi
    warn "Before each future kernel upgrade, purge the previous kernel first"
    warn "(dpkg -l 'linux-image-*', then: sudo apt purge <old versions>)."
    return 0
}

do_conversion() {
    # The keyring download needs only wget and the CA bundle, both present on
    # any normal install - skip refreshing the soon-to-be-disabled Debian
    # indexes unless something is actually missing.
    if ! command -v wget > /dev/null 2>&1 || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
        log "Installing prerequisites (wget, ca-certificates)"
        apt_ni update
        apt_ni install -y wget ca-certificates
    fi
    install_keyring
    write_kali_sources
    disable_debian_sources
    log "Updating package lists from Kali"
    run_step_with_recovery apt_ni update
    log "Rebasing base system onto kali-rolling (this can take a while)..."
    run_step_with_recovery apt_ni -y full-upgrade
    log "Installing kali-archive-keyring and ${KALI_METAPACKAGE}"
    run_step_with_recovery apt_ni install -y kali-archive-keyring "$KALI_METAPACKAGE"
    log "Removing packages that are no longer required"
    apt_ni -y autoremove --purge
    # Drop the multi-GB .deb cache the rebase left behind. Best-effort: the
    # EXIT trap is still armed, and hygiene must not report a failed conversion.
    apt_ni clean || true
    finish_conversion
    ok "Conversion complete. New system identity:"
    grep -E '^(PRETTY_NAME|ID|VERSION)=' "$OS_RELEASE_FILE" | sed 's/^/    /'
    post_conversion_esp_advice
    warn "A reboot is recommended: sudo reboot"
}

main() {
    parse_args "$@"
    # Elevate before the checks so they, and the confirmation, run exactly once.
    if [ "$(id -u)" -ne 0 ]; then
        log "Elevating privileges with sudo..."
        exec sudo bash "$0" "$@"
    fi
    sweep_legacy_backups
    # A marker from an interrupted conversion switches to resume mode (checked
    # as root - the marker is root-owned); os-release may already report Kali
    # mid-conversion, so the already-Kali and distro checks are skipped.
    if [ -f "$STATE_FILE" ]; then
        RESUME=true
        if conversion_complete; then
            finish_conversion
            ok "Previous conversion is already complete - removed the leftover resume marker."
            exit 0
        fi
        warn "Interrupted conversion detected ($STATE_FILE) - resuming."
    else
        check_already_kali
        check_supported_distro
    fi
    # Prompts (remediations, the YES confirmation) need a terminal; without
    # one, reads would hang or mis-answer. Placed after the zero-work exits
    # so probing an already-converted box without --yes stays a friendly
    # exit 0, and before preflight so no remediation can mutate the system
    # on a run that could never be confirmed.
    if ! $ASSUME_YES && [ ! -t 0 ]; then
        err "stdin is not a terminal; re-run with --yes for unattended use."
    fi
    preflight
    resolve_metapackage
    confirm
    mark_conversion_started
    if $RESUME; then run_step_with_recovery repair_packages; fi
    do_conversion
}

# Run main only when executed, not when sourced (enables unit testing).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
UPGRADE_TO_KALI_EOF
    log "upgrade-to-kali installed at $dest (run: sudo upgrade-to-kali)"
}
install_upgrade_to_kali

# Install and configure ufw-docker
log "Installing ufw-docker..."
if ! command -v ufw-docker &> /dev/null; then
    # Non-fatal: a failed download is recorded in the end-of-run summary, skips
    # the rules below, and retries on the next run (the command -v gate above)
    # instead of aborting the whole run this late.
    if fetch_install --sudo --mode 755 https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker /usr/local/bin/ufw-docker; then
        log "ufw-docker installed successfully"
    else
        note_build_failure "ufw-docker"
    fi
else
    log "ufw-docker is already installed"
fi
# Apply ufw-docker rules only when the firewall is already active. We never enable
# ufw ourselves (that risks SSH lockout), so this fires only on an already-firewalled
# box. LC_ALL is passed on sudo's command line (sudo resets the env, so the global
# export doesn't reach it) to force a locale-independent "Status: active" match.
if command -v ufw-docker &> /dev/null && command -v docker &> /dev/null && command -v ufw &> /dev/null \
        && sudo LC_ALL=C.UTF-8 ufw status 2>/dev/null | grep -Fq "Status: active"; then
    if sudo grep -q "^# BEGIN UFW AND DOCKER" /etc/ufw/after.rules 2>/dev/null; then
        log "ufw-docker rules already present in /etc/ufw/after.rules; nothing to do"
    else
        warn "ufw is active. Applying ufw-docker BLOCKS external access to all published"
        warn "Docker container ports (FORWARD/DOCKER-USER chain only - host services like"
        warn "SSH are unaffected). Re-expose a port with: sudo ufw-docker allow <container> <port>"
        # sudo: on a fresh install the user's docker group membership is not
        # effective until re-login, so a plain docker ps would silently fail
        # and the listing would never show on the run where it matters most.
        published="$(sudo docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -F '->' || true)"
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
    log "ufw not active (or docker/ufw-docker missing); skipping ufw-docker rules"
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
    # Restart only when the drop-in actually changed (CONFIG_CHANGED is set by
    # write_config_file); the resolv.conf symlink alone needs no restart.
    if [ "$CONFIG_CHANGED" = true ]; then
        sudo systemctl restart systemd-resolved || true
    fi
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
# Release the temporary swapfile here (swapoff pages everything back into RAM
# and can be slow) rather than after the success banner; the EXIT trap that
# also calls this then no-ops via the SWAP_ACTIVE guard.
cleanup_temp_swap

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
    warn "These optional tools were skipped after a failed build/download:"
    for t in "${FAILED_BUILDS[@]}"; do warn "  - $t"; done
    warn "Your shell is fully configured regardless. Re-run to retry."
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
