#!/bin/bash

# Linux Setup Script
# Configures a fresh Debian / Kali Linux installation with development tools and customizations

set -euo pipefail

VERSION="1.1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Backup a file with timestamp
backup_file() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        local backup_path="${file_path}.backup.$(date +'%Y-%m-%d_%H-%M-%S')"
        cp "$file_path" "$backup_path"
        log "Backed up to: $backup_path"
    fi
}

# Prompt user with yes/no question
# Usage: prompt_yes_no "Question?" "Y" (or "N" for default No)
# Returns: 0 for yes, 1 for no
prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local response

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

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    warn "This script should normally not be run as root. Please run as a regular user with sudo privileges."
fi

# Check if we're on a Debian-based system (hard requirement)
if ! grep -qE "(debian|ID_LIKE.*debian)" /etc/os-release 2>/dev/null; then
    error "This script requires a Debian-based Linux distribution. Detected system is not compatible."
fi

# Check if we're on Kali Linux (preferred but not required)
is_kali_linux() {
    grep -q "Kali" /etc/os-release 2>/dev/null
}

# Check if desktop environment is available
has_desktop_environment() {
    # Check for graphical systemd targets
    if systemctl is-active --quiet graphical.target 2>/dev/null || \
       systemctl is-active --quiet graphical-session.target 2>/dev/null; then
        return 0
    fi

    # Check for desktop environment processes (expanded list for Gnome, KDE, XFCE, etc.)
    if pgrep -f "xfce4-session\|gnome-session\|gnome-shell\|kde-session\|lxsession\|plasma\|cinnamon" > /dev/null 2>&1; then
        return 0
    fi

    # Check for display server environment variables (X11 or Wayland)
    if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
        return 0
    fi

    # Check for desktop environment configuration tools
    if command -v xfconf-query &> /dev/null || \
       command -v gsettings &> /dev/null; then
        return 0
    fi

    return 1
}

# Install Rust via rustup
install_rust_via_rustup() {
    log "Installing Rust via rustup (official Rust installer)..."

    # Download and run rustup-init
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable

    # Source cargo environment for this script
    export CARGO_HOME="$HOME/.cargo"
    export RUSTUP_HOME="$HOME/.rustup"
    export PATH="$CARGO_HOME/bin:$PATH"

    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env"
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
    BEHIND=$(git rev-list HEAD..@{u} 2>/dev/null | wc -l)

    if [ "$BEHIND" -gt 0 ]; then
        log "Updates found! Pulling latest changes..."
        git pull --ff-only
        log "Re-executing updated script..."
        exec "$0" "$@"
        exit 0
    else
        log "Script is up to date"
    fi
else
    warn "Not running from a git repository. Self-update disabled."
fi

#############################################################################
# PHASE 1: System Setup
#############################################################################

log "Starting Linux setup..."

# Update package lists and upgrade system
log "Updating package lists and upgrading system..."
sudo apt-get update
sudo apt-get dist-upgrade -y

# Install essential packages
log "Installing essential packages..."
sudo apt-get install -y \
    ca-certificates \
    build-essential \
    curl \
    wget \
    git \
    fzf \
    tree \
    hstr \
    bubblewrap \
    ripgrep \
    sd \
    fd-find \
    moreutils \
    unp \
    htop \
    ncdu \
    lsof \
    jq \
    bat \
    exiftool \
    libpcap-dev \
    ufw \
    python3-dev \
    python3-pip \
    python3-venv \
    golang \
    zsh

# Install Rust - either from repo (if >= 1.85) or via rustup
log "Checking Rust version in repositories..."
REPO_RUST_VERSION=$(apt-cache policy rustc 2>/dev/null | grep -oP 'Candidate:\s*\K[0-9]+\.[0-9]+' | head -1)

if [ -z "$REPO_RUST_VERSION" ]; then
    REPO_RUST_VERSION="0.0"
    warn "Could not determine repository Rust version"
fi

# Convert version to comparable number (e.g., "1.85" -> 185)
REPO_RUST_VERSION_NUM=$(echo "$REPO_RUST_VERSION" | awk -F. '{print ($1 * 100) + $2}')
MINIMUM_RUST_VERSION=185  # Rust 1.85 minimum for modern tools

log "Repository has Rust version: $REPO_RUST_VERSION (numeric: $REPO_RUST_VERSION_NUM, minimum required: $MINIMUM_RUST_VERSION)"

if ! command -v cargo &> /dev/null; then
    # Rust not installed - choose installation method based on repo version
    if [ "$REPO_RUST_VERSION_NUM" -ge "$MINIMUM_RUST_VERSION" ]; then
        log "Installing Rust from repositories (version $REPO_RUST_VERSION)..."
        sudo apt-get install -y cargo rustc
    else
        log "Repository version $REPO_RUST_VERSION is < 1.85, installing Rust via rustup..."
        install_rust_via_rustup
    fi
else
    log "Rust is already installed"
fi

# Install Node.js - either from repo (if >= 20) or via nvm
log "Checking Node.js version in repositories..."
REPO_NODE_VERSION=$(apt-cache policy nodejs 2>/dev/null | grep -oP 'Candidate:\s*\K[0-9]+' | head -1)

if [ -z "$REPO_NODE_VERSION" ]; then
    REPO_NODE_VERSION=0
    warn "Could not determine repository Node.js version"
fi

MINIMUM_NODE_VERSION=20

log "Repository has Node.js version: $REPO_NODE_VERSION (minimum required: $MINIMUM_NODE_VERSION)"

if ! command -v node &> /dev/null; then
    # Node.js not installed - choose installation method based on repo version
    if [ "$REPO_NODE_VERSION" -ge "$MINIMUM_NODE_VERSION" ]; then
        log "Installing Node.js from repositories (version $REPO_NODE_VERSION)..."
        sudo apt-get install -y nodejs npm
    else
        log "Repository version $REPO_NODE_VERSION is < 20, installing Node 22 via nvm..."

        # Install nvm
        if [ ! -d "$HOME/.nvm" ]; then
            log "Installing nvm..."
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash

            # Source nvm immediately for this script
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        else
            log "nvm is already installed"
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        fi

        # Install Node 22 via nvm
        log "Installing Node.js 22 via nvm..."
        nvm install 22
        nvm use 22
        nvm alias default 22

        # Set flag to indicate nvm was installed (for .zshrc update)
        NVM_INSTALLED=true
    fi
else
    log "Node.js is already installed"
fi

# Install GUI applications if desktop environment is available
if has_desktop_environment; then
    log "Desktop environment detected - installing GUI applications"
    sudo apt-get install -y \
        gedit \
        gedit-plugins \
        fonts-firacode \
        terminator \
        meld \
        xsel
        
    # Configure GTK terminal padding
    log "Configuring GTK terminal padding..."
    mkdir -p ~/.config/gtk-3.0
    cat > ~/.config/gtk-3.0/gtk.css << 'EOF'
VteTerminal, TerminalScreen, vte-terminal {
    padding: 8px 8px 8px 8px; /* Top Right Bottom Left */
    -VteTerminal-inner-border: 8px 8px 8px 8px; /* Older versions might need this */
}
EOF
else
    log "No desktop environment detected - skipping GUI applications"
fi

# Install Kali-specific package - only install on Kali Linux
if is_kali_linux; then
    log "Installing hacking tools..."
    sudo apt-get install -y massdns mitmproxy || true
else
    warn "Skipping hacking tools installation - only available on Kali Linux"
fi

# Install pipx (Python application installer)
log "Installing pipx..."
if ! command -v pipx &> /dev/null; then
    #python3 -m pip install --user pipx
    sudo apt-get install -y pipx
else
    log "pipx is already installed"
fi

# Install uv (modern Python package installer)
log "Installing uv..."
export PATH=$HOME/.local/bin:$PATH
if ! command -v uv &> /dev/null; then
    pipx install uv
else
    log "uv is already installed"
fi

# Install Python tools with uv
log "Installing Python tools with uv..."
if command -v uv &> /dev/null; then
    uv tool install httpie
    uv tool install name-that-hash
    uv tool install tldr
else
    warn "uv not available, skipping Python tools installation"
fi

# Install Docker CE
log "Installing Docker CE..."
if ! command -v docker &> /dev/null; then
    # Remove conflicting packages
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove -y $pkg || true; done
    
    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources
    DOCKER_CODENAME="bookworm"
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $DOCKER_CODENAME stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker CE
    sudo apt-get update
    sudo apt-get install -y docker-ce
    
    # Enable and start Docker service
    sudo systemctl enable docker
    sudo systemctl start docker
    
    log "Docker CE installed and started successfully. You'll need to log out and back in for group changes to take effect."
else
    log "Docker is already installed"
fi

# Configure Docker group and permissions
log "Configuring Docker group and permissions..."
sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker $USER
if [[ -d /home/"$USER"/.docker ]]; then
    sudo chown "$USER":"$USER" /home/"$USER"/.docker -R
    sudo chmod g+rwx "$HOME/.docker" -R
fi

# Install Visual Studio Code
if has_desktop_environment; then
    log "Installing Visual Studio Code..."
    if ! command -v code &> /dev/null; then
        sudo apt-get install -y wget gpg
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
        sudo install -D -o root -g root -m 644 microsoft.gpg /usr/share/keyrings/microsoft.gpg
        rm -f microsoft.gpg
        
        # Create VSCode sources file
        sudo tee /etc/apt/sources.list.d/vscode.sources > /dev/null << 'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
        
        sudo apt-get install -y apt-transport-https
        sudo apt-get update
        sudo apt-get install -y code
    else
        log "Visual Studio Code is already installed"
    fi
else
    log "No desktop environment detected - skipping Visual Studio Code installation"
fi

# Install up tool
log "Installing up tool..."
if ! command -v up &> /dev/null; then
    export PATH=$HOME/go/bin:$PATH
    go install -v github.com/akavel/up@latest
    sudo cp $(which up) /usr/local/bin/ 2>/dev/null || sudo cp $HOME/go/bin/up /usr/local/bin/
else
    log "up tool is already installed"
fi

# Install zoxide (smarter cd)
log "Installing zoxide..."
if ! command -v zoxide &> /dev/null; then
    cargo install zoxide --locked
else
    log "zoxide is already installed"
fi

# Disable screensaver and power management
if has_desktop_environment; then
    log "Disabling screensaver and power save options..."
    if command -v xfconf-query &> /dev/null; then
        # Disable screensaver and lock screen (create setting if it doesn't exist)
        xfconf-query -c xfce4-screensaver -p /saver/enabled --create -t bool -s false
        xfconf-query -c xfce4-screensaver -p /lock/enabled --create -t bool -s false
        
        # Disable Display Power Management entirely
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled --create -t bool -s false
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
    cat > ~/.config/xfce4/helpers.rc << 'EOF'
TerminalEmulator=terminator
EOF
else
    log "No desktop environment detected - skipping terminal configuration"
fi

# Configure zsh with Kali Linux default baseline plus enhancements
log "Configuring zsh..."

# Check if .zshrc exists and prompt for overwrite
OVERWRITE_ZSHRC=true
if [ -f ~/.zshrc ]; then
    backup_file ~/.zshrc
    if ! prompt_yes_no "Overwrite existing .zshrc (initially strongly recommended!)?" "Y"; then
        OVERWRITE_ZSHRC=false
        log "Keeping existing .zshrc"
    fi
fi

if [ "$OVERWRITE_ZSHRC" = true ]; then
cat > ~/.zshrc << 'EOF'
# Default ~/.zshrc from Kali Linux
# ~/.zshrc file for zsh interactive shells.
# see /usr/share/doc/zsh/examples/zshrc for examples

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
compinit -d ~/.cache/zcompdump
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
    prompt_symbol=㉿
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

    # enable syntax-highlighting
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
bindkey ^P toggle_oneline_prompt

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
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
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

    # Take advantage of $LS_COLORS for completion as well
    zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
    zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
fi

# some more ls aliases
alias ll='ls -l'
alias la='ls -A'
alias l='ls -CF'

# enable auto-suggestions based on the history
if [ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
    . /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
    # change suggestion color
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#999'
fi

# enable command-not-found if installed
if [ -f /etc/zsh_command_not_found ]; then
    . /etc/zsh_command_not_found
fi

# ==========================================
# Linux Setup Script Custom Enhancements
# ==========================================

unset ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE

# Enhanced tab completion
setopt complete_in_word       # cd /ho/ka/Dow<TAB> expands to /home/kali/Downloads

# zoxide - smarter cd command
# Only initialize in interactive shells to avoid interfering with automation tools
if command -v zoxide &> /dev/null && [[ -o interactive ]]; then
    eval "$(zoxide init zsh --cmd cd)"
fi

# Enhanced history settings
HISTSIZE=999999999
SAVEHIST=$HISTSIZE
setopt share_history          # share command history data
setopt hist_find_no_dups
setopt hist_reduce_blanks
#setopt hist_ignore_all_dups   # as the name says, beware!

# Better history incremental search
multibind () {  # <cmd> <in-string> [<in-string>...]
  emulate -L zsh
  local cmd=$1; shift
  for 1 { bindkey $1 $cmd }
}
# Keys: up; down  
autoload -Uz history-search-end
zle -N history-beginning-search-backward-end history-search-end
zle -N history-beginning-search-forward-end  history-search-end
multibind history-beginning-search-backward-end '^[OA' '^[[A'  # up
multibind history-beginning-search-forward-end  '^[OB' '^[[B'  # down
zle -A {.,}history-incremental-search-forward
zle -A {.,}history-incremental-search-backward

# Remove trailing newlines if any from pasted text
bracketed-paste() {
  zle .$WIDGET && LBUFFER=$(echo -En $LBUFFER)
}
zle -N bracketed-paste

# HSTR configuration
alias hh=hstr                    # hh to be alias for hstr
setopt histignorespace           # skip cmds w/ leading space from history
export HSTR_CONFIG=hicolor,raw-history-view      # get more colors
hstr_no_tiocsti() {
    zle -I
    { 
    MERGE="hstr ${BUFFER};"
    HSTR_OUT=$({ </dev/tty eval " $MERGE" } 2>&1 1>&3 3>&- ); 
    } 3>&1;
    BUFFER="${HSTR_OUT}"
    CURSOR=${#BUFFER}
    zle redisplay
}
zle -N hstr_no_tiocsti
bindkey '\C-r' hstr_no_tiocsti
export HSTR_TIOCSTI=n

# https://github.com/akavel/up/ https://github.com/akavel/up/issues/44
UPCOMMAND="bwrap --die-with-parent --ro-bind / / --bind /tmp /tmp --dev /dev --proc /proc --tmpfs /var --tmpfs /run --dir /run/user/$UID --unshare-pid --unshare-cgroup --unshare-ipc /usr/local/bin/up"
zle-upify() {
    local args=""

    if [[ -n "$ZSH_UP_UNSAFE_FULL_THROTTLE" ]]; then 
        args="$args --unsafe-full-throttle"
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
alias polster='bwrap --die-with-parent --tmpfs /tmp --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 --ro-bind /sbin /sbin --ro-bind /etc /etc --dev /dev --proc /proc --tmpfs /var --tmpfs /run --dir /run/user/$UID --tmpfs /usr/share --unshare-all --clearenv'

alias upgrade-all='sudo apt-get update && sudo apt-get dist-upgrade; pipx upgrade-all; uv tool upgrade --all'
alias fd='fdfind'
alias pbcopy='xsel --clipboard --input'
alias pbpaste='xsel --clipboard --output'
alias bat='batcat --theme=Coldark-Cold'
alias cat='batcat --theme=Coldark-Cold --paging=never'

alias sudo='sudo '
alias sudp='sudo '

# Directory creation helpers
mkcd() {
  mkdir -p -- "$1" &&
  \cd -- "$1"
}

tempe() {
  \cd "$(mktemp -d)"
  chmod -R 0700 .
  if [[ $# -eq 1 ]]; then
    \mkdir -p "$1"
    \cd "$1"
    chmod -R 0700 .
  fi
}

# Go PATH configuration
export PATH=$HOME/go/bin:$PATH

# Rust/Cargo PATH configuration
export PATH=$HOME/.cargo/bin:$PATH

# Python uv and local packages PATH configuration
export PATH=$HOME/.local/bin:$PATH
EOF
fi

# Add nvm initialization to .zshrc if nvm was installed
if [ "${NVM_INSTALLED:-false}" = "true" ]; then
    log "Adding nvm initialization to .zshrc..."
    cat >> ~/.zshrc << 'EOF'

# nvm (Node Version Manager) configuration
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
fi

# Change default shell to zsh if not already zsh
log "Checking default shell..."
if [[ "$SHELL" != "/usr/bin/zsh" && "$SHELL" != "/bin/zsh" ]]; then
    if prompt_yes_no "Change default shell to zsh?" "Y"; then
        sudo chsh -s $(which zsh) $USER
        log "Default shell changed to zsh. You'll need to log out and back in for the change to take effect."
    else
        log "Keeping current shell: $SHELL"
    fi
else
    log "Shell is already set to zsh"
fi

# Configure Terminator
if has_desktop_environment; then
    log "Configuring Terminator..."
    mkdir -p ~/.config/terminator

    # Check if Terminator config exists and prompt for overwrite
    OVERWRITE_TERMINATOR=true
    if [ -f ~/.config/terminator/config ]; then
        backup_file ~/.config/terminator/config
        if ! prompt_yes_no "Overwrite existing Terminator config?" "N"; then
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
  edit_tab_title = <Super>r
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
    if [[ ! -d ~/.config/terminator/plugins ]]; then
        mkdir -p ~/.config/terminator/plugins
    fi

    if [[ ! -f ~/.config/terminator/plugins/tab_numbers.py ]]; then
        wget -O ~/.config/terminator/plugins/tab_numbers.py https://raw.githubusercontent.com/c0ffee0wl/terminator-tab-numbers-plugin/main/tab_numbers.py
        if [[ $? -eq 0 ]]; then
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

if is_kali_linux; then

    # Install Project Discovery tool manager (Kali-specific tools)
    log "Installing Project Discovery tool manager..."
    if ! command -v pdtm &> /dev/null; then
        go install -v github.com/projectdiscovery/pdtm/cmd/pdtm@latest
    else
        log "pdtm is already installed"
    fi
    
    # Install all Project Discovery tools
    log "Installing all Project Discovery tools..."
    if command -v pdtm &> /dev/null; then
        pdtm -install-all
        log "Updating all Project Discovery tools..."
        pdtm -update-all
    else
        warn "pdtm installation failed, skipping tool installation"
    fi

    # Install BloodHoundAnalyzer (Kali-specific tools)
    if [[ ! -d /opt/BloodHoundAnalyzer ]]; then
        log "Installing BloodHoundAnalyzer..."
        sudo git clone --depth=1 https://github.com/c0ffee0wl/BloodHoundAnalyzer /opt/BloodHoundAnalyzer
        sudo chown -R "$(whoami)":"$(whoami)" /opt/BloodHoundAnalyzer
        cd /opt/BloodHoundAnalyzer && ./install.sh
    else
        log "BloodHoundAnalyzer is already installed"
    fi

    # Install Python tools with uv (Kali-specific tools)
    log "Installing Python tools for Kali with uv..."
    if command -v uv &> /dev/null; then
        uv tool install bbot
        uv tool install git+https://github.com/Pennyw0rth/NetExec
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
    sudo wget -O /usr/local/bin/ufw-docker https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
    sudo chmod +x /usr/local/bin/ufw-docker
    
    log "ufw-docker installed successfully"
else
    log "ufw-docker is already installed"
fi
log "Enable ufw and ufw-docker with: "
log "sudo ufw enable && sudo ufw-docker install && sudo systemctl restart ufw"

# Configure systemd-resolved to disable stub listener if installed
log "Configuring systemd-resolved..."
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    log "systemd-resolved is active, configuring..."
    sudo mkdir -p /etc/systemd/resolved.conf.d/
    sudo tee /etc/systemd/resolved.conf.d/disable-stub.conf > /dev/null << 'EOF'
[Resolve]
DNSStubListener=no
EOF
    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    sudo systemctl restart systemd-resolved
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
sudo apt-get autoremove -y
sudo apt-get clean
go clean -cache -modcache || true

# Configure Xfce keyboard layout to German
if has_desktop_environment; then
    if command -v xfconf-query &> /dev/null; then
        if prompt_yes_no "Configure German keyboard layout in XFCE?" "Y"; then
            log "Configuring Xfce keyboard layout to German..."
            xfconf-query -c keyboard-layout -p /Default/XkbDisable --create -t bool -s false
            xfconf-query -c keyboard-layout -p /Default/XkbLayout --create -t string -s "de"
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

log "Setup complete!"
echo -e "${BLUE}===========================================${NC}"
echo -e "${BLUE}  Linux Setup Complete!${NC}"
echo -e "${BLUE}===========================================${NC}"

echo
echo -e "${YELLOW}Please log out and log back in for all changes to take effect.${NC}"
