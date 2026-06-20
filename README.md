# Linux Setup Script

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Overview](#overview)
- [Requirements](#requirements)
- [Installation](#installation)
  - [Quick Start](#quick-start)
  - [Usage](#usage)
  - [What the script does:](#what-the-script-does)
- [Post-Installation](#post-installation)
- [Usage Examples](#usage-examples)
  - [Terminator Terminal](#terminator-terminal)
    - [Terminator Keyboard Shortcuts](#terminator-keyboard-shortcuts)
  - [Shell Operations Previewed in Ultimate Plumber](#shell-operations-previewed-in-ultimate-plumber)
  - [ripgrep (rg) - Fast Recursive Search](#ripgrep-rg---fast-recursive-search)
  - [sd - Search & Displace (sed replacement)](#sd---search--displace-sed-replacement)
  - [delta - Git Diff Viewer](#delta---git-diff-viewer)
  - [fd - Fast File Finder](#fd---fast-file-finder)
  - [moreutils - Advanced Unix Tools](#moreutils---advanced-unix-tools)
  - [tldr - Simplified Command Examples](#tldr---simplified-command-examples)
  - [bat - Syntax-Highlighted File Viewer](#bat---syntax-highlighted-file-viewer)
  - [jq - JSON Processor](#jq---json-processor)
  - [yq - YAML/TOML/XML Processor](#yq---yamltomlxml-processor)
  - [Arrow Key History Search](#arrow-key-history-search)
  - [hstr - Enhanced History Search](#hstr---enhanced-history-search)
  - [unp - Universal Unpacker](#unp---universal-unpacker)
  - [httpie - User-Friendly HTTP Client](#httpie---user-friendly-http-client)
  - [ncdu - Disk Usage Analyzer](#ncdu---disk-usage-analyzer)
  - [uv - Fast Python Package Manager](#uv---fast-python-package-manager)
  - [fzf - Fuzzy Finder](#fzf---fuzzy-finder)
  - [zoxide - Smart Directory Navigation](#zoxide---smart-directory-navigation)
  - [Shell Helper Functions](#shell-helper-functions)
  - [eget - Easy Binary Installation](#eget---easy-binary-installation)
  - [gitsnip - Download Specific Folders from Git Repositories](#gitsnip---download-specific-folders-from-git-repositories)
  - [lazygit - Terminal UI for Git Commands](#lazygit---terminal-ui-for-git-commands)
  - [lazydocker - Terminal UI for Docker](#lazydocker---terminal-ui-for-docker)
- [Configuration Files](#configuration-files)
- [Security Considerations](#security-considerations)
- [Compatibility](#compatibility)
- [Tools Reference](#tools-reference)
  - [Core System Tools](#core-system-tools)
  - [Modern CLI Alternatives](#modern-cli-alternatives)
  - [Shell & Terminal](#shell--terminal)
  - [Programming Languages & Runtimes](#programming-languages--runtimes)
  - [Python Package Managers & Tools](#python-package-managers--tools)
  - [Containerization & Security](#containerization--security)
  - [GUI Applications (Only Installed When GUI Detected)](#gui-applications-only-installed-when-gui-detected)
  - [Kali Linux Specific Tools (Only Installed on Kali)](#kali-linux-specific-tools-only-installed-on-kali)
- [Troubleshooting](#troubleshooting)
  - [Common Issues](#common-issues)
  - [Debug Mode](#debug-mode)
- [Customization](#customization)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgments](#acknowledgments)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

A Bash script that sets up a fresh Debian, Ubuntu, or Kali install with development tools, terminal tweaks, and security hardening.

## Overview

Built for a fresh install and safe to re-run: it skips whatever is already in place and backs up files before touching them. It works on any Debian base but is tuned for Kali. It's for security folks and developers who rebuild machines often and want the same setup every time instead of redoing it by hand.

## Requirements

- **OS**: Debian-based Linux distribution (Ubuntu, Debian, Kali Linux)
- **Network**: Internet connection for package downloads
- **Storage**: ~2GB free space for all tools and dependencies

## Installation

### Quick Start
```bash
git clone https://github.com/c0ffee0wl/linux-setup.git
cd linux-setup
./linux-setup.sh
```

### Usage

The script supports the following command-line options:

```bash
./linux-setup.sh           # Interactive mode (default) - prompts for user confirmation
./linux-setup.sh --force   # Non-interactive mode - auto-answers "Yes" to all prompts
./linux-setup.sh --help    # Display usage information

# NOT RECOMMENDED ON FIRST RUN, because then some customizations are not installed
./linux-setup.sh --no      # Non-interactive mode - auto-answers "No" to all prompts

# Skip hacking tools even on Kali Linux
./linux-setup.sh --no-hacking-tools

# Skip configuring the German XFCE keyboard layout (useful with --force)
./linux-setup.sh --no-keyboard-layout

# Apply only supply-chain hardening configs (no package installs, no shell changes)
./linux-setup.sh --harden-only
```

**Interactive Mode (default):**
By default, the script will prompt you for confirmation on certain actions:
- Overwriting existing `.zshrc` configuration (default: Yes)
- Changing default shell to zsh (default: Yes)
- Overwriting existing Terminator configuration (default: No)
- Configuring German keyboard layout in XFCE (default: No; skip entirely with `--no-keyboard-layout`)

**Notes:**
- The script makes a timestamped backup before overwriting any file
- All package installations (Docker, Go, Rust, Bun, tools, etc.) happen automatically without prompts

**Force Mode (`--force` or `-f`):**
Use this flag to run the script non-interactively, automatically answering "Yes" to all prompts. This is useful for:
- Automated/unattended installations
- Running in scripts or provisioning tools

**No Mode (`--no` or `-n`):**
Use this flag to run the script non-interactively, automatically answering "No" to all prompts. This is useful for:
- Installing packages without overwriting existing configurations
- Running the script but skipping optional configurations

**No Hacking Tools (`--no-hacking-tools`):**
Use this flag to skip installation of hacking/pentest tools even when running on Kali Linux. Skipped tools include:
- massdns, mitmproxy
- Project Discovery tools (pdtm and all tools it installs)
- BloodHoundAnalyzer
- bbot, NetExec

**No Keyboard Layout (`--no-keyboard-layout`):**
Use this flag to skip configuring the German XFCE keyboard layout. By default this is only applied if you answer "Yes" to the interactive prompt (default: No), but `--force` auto-answers "Yes", so pass this flag together with `--force` to keep your existing keyboard layout in unattended runs.

**Harden Only (`--harden-only`):**
Use this flag to apply only supply-chain hardening configurations without installing any packages or changing shell/terminal settings. This writes package manager configs (npm, Bun, Cargo, uv, pip), system-level fallback configs, telemetry opt-outs, and Go module hardening environment variables. Useful for:
- Hardening existing systems without a full setup run
- Applying hardening to systems where tools were installed manually
- Refreshing hardening configs after dotfile changes

### What the script does:
1. **System verification**: Checks OS compatibility and user privileges
2. **Package updates**: Updates system packages and repositories
3. **Tool installation**: Installs all development and productivity tools
4. **Configuration**: Sets up shell, terminal, and system preferences (on XFCE, disables the screensaver, lock screen, and display power management/DPMS)
5. **Security setup**: Configures Docker and sandboxing tools
6. **Cleanup**: Removes unnecessary packages and cleans package cache

## Post-Installation

After running the script:

1. **Log out and back in** for all changes to take effect
2. **Verify installations**:
   ```bash
   docker --version
   go version
   rustc --version
   bun --version
   ```

## Usage Examples

Examples of the installed tools in action.

### Terminator Terminal

The script sets Terminator as the default terminal, with custom keybindings and a few tweaked defaults.

> **Want an AI agent built into your terminal?** This setup ships Terminator. If you'd rather have an LLM agent living in the terminal itself, take a look at [zap-setup](https://github.com/c0ffee0wl/zap-setup), a companion installer for the [Zap](https://github.com/zerx-lab/zap) terminal. It installs Zap, gives it Terminator-style keybindings and a matching light theme, and pre-wires the agent so you can point it at whatever LLM provider you like. A local LiteLLM proxy is set up out of the box, but any provider Zap supports works just as well. The AI side is optional too, so Zap still works as a plain terminal if you never add a key. It's a separate program, not part of this script.

#### Terminator Keyboard Shortcuts

**Tab Management:**
- `Ctrl+T` - Open new tab
- `Ctrl+Tab` - Next tab
- `Ctrl+Shift+Tab` - Previous tab
- `Ctrl+1` through `Ctrl+6` - Switch to tab 1-6 directly
- `Ctrl+Shift+Page_Down` - Move current tab right
- `Ctrl+Shift+Page_Up` - Move current tab left
- `Alt+<Arrow>` - Switch to left/right/upper/lower terminal
- `Super+N` - Insert tab number in terminal
- `Super+Q` - Rename/edit tab title

**Window Splitting:**
- `Super+Y` - Split terminal horizontally
- `Super+A` - Split terminal vertically
- `Ctrl+Shift+Super+D` - Close window

**Search & Navigation:**
- `Ctrl+F` - Search in terminal output

**Terminal Features:**
- **Copy on selection** - Text is automatically copied when selected
- **Infinite scrollback** - Never lose terminal history
- **Tab numbers plugin** - Visual tab numbers for easy navigation

> **Note**: `Super` key is typically the Windows/Command key on most keyboards.

> **Note**: `Ctrl+D` on an empty prompt closes a terminal by sending EOF to the shell - this is standard shell behavior, not a Terminator keybinding (Terminator's own close-terminal shortcut is left unbound).

### Shell Operations Previewed in Ultimate Plumber

Classic Unix command pipelines with `awk`, `cut`, and `sed`, previewed with [up - the Ultimate Plumber](https://github.com/akavel/up), safely [bubblewrapped](https://github.com/containers/bubblewrap) in a sandbox.

```bash
# Build a pipeline interactively with up (Ultimate Plumber) via the Ctrl+P integration
cat users.txt |    # Press Ctrl+P to pipe the current command line into up
# Refine the pipeline against the live sandboxed preview, then press Ctrl+X to exit up:
# the built pipeline is placed on your command line. Press Enter to actually run it.

# Process user data: extract field, trim path, remove header/footer
cat users.txt | awk '{print $5}' | cut -d '/' -f2 | sed '1,2d; $d'

# Sandboxed shell execution with bubblewrap (polster is a custom alias defined by this setup)
polster sh         # Isolated, restricted shell environment
```

### [ripgrep](https://github.com/BurntSushi/ripgrep) (rg) - Fast Recursive Search

```bash
# Clone example repository for testing
git clone --depth=1 https://github.com/Orange-Cyberdefense/GOAD.git
cd GOAD

# Basic search (respects .gitignore by default)
rg hodor

# Case-insensitive search with context lines
rg -i "night watch" -C2

# Search with more context
rg "horse" -C4

# Performance comparison
time rg -i hodor
time grep -i hodor -r

# Additional ripgrep flags:
#   -i: case insensitive
#   -v: invert matching
#   -A n: show n lines after match
#   -B n: show n lines before match
#   -C n: show n lines of context (before and after)
#   -u: ignore .gitignore; -uu: also search hidden files; -uuu: also search binary files
#   -l: list files matching
#   -e: pattern (regex) to search for
#   -o: show only matching fragment
```

### [sd](https://github.com/chmln/sd) - Search & Displace (sed replacement)

```bash
# Simple text replacement
sd "horse" "Pferd" ad/GOAD/data/config.json

# Pipeline usage - replace newlines with commas
cat ~/users.txt | sd '\n' ',' | tail

# Extract path components with regex capture groups
echo "sample with /path/" | sd '.*(/.*/)' '$1'
```

### [delta](https://github.com/dandavison/delta) - Git Diff Viewer

`delta` is configured as the default git pager for syntax-highlighted diffs:

```bash
# View git diff with syntax highlighting (automatic - just use git as normal)
git diff

# Side-by-side view
git -c delta.side-by-side=true diff

# View git log with diff
git log -p
```

### [fd](https://github.com/sharkdp/fd) - Fast File Finder

```bash
# Find files by name pattern
fd rockyou /

# Find all filenames containing "rdp"
fd rdp

# Find hidden files in home directory
fd --hidden zsh ~

# Find only directories
fd --type d

# Find by file extension
fd -e md

# Find and execute commands on results
fd README --type f --exec wc -w   # Count words in all README files
```

### [moreutils](https://joeyh.name/code/moreutils/) - Advanced Unix Tools

The `moreutils` package includes several useful utilities, with `sponge` being particularly helpful for in-place file editing:

```bash
# Problem: Standard piping overwrites the file before reading
cat users.txt | awk '{print $4}' > users.txt   # This BREAKS the file!

# Solution: Use sponge to safely modify files in-place
cat users.txt | awk '{print $4}' | sponge users.txt   # Safe in-place edit

# Backup before using sponge
cp users.txt{,.bup}

# Example: Extract column 4 and overwrite original file
cat users.txt | awk '{print $4}' | sponge users.txt

# Restore from backup if needed
rm users.txt
cp users.txt.bup users.txt

# NOTE: sponge soaks up ALL of stdin before writing the file. Small inputs are held
# in memory; large inputs spill to a temp file in $TMPDIR (ideally on the same
# filesystem as the target, so the atomic rename works). It also blocks until the
# producing command finishes - avoid unbounded/never-ending streams.
```

Other useful tools from `moreutils`:
- `combine`: Combine files using set operations
- `chronic`: Run commands quietly unless they fail
- `ts`: Add timestamps to output
- `vidir`: Edit directory contents in your text editor
- `vipe`: Edit pipe data interactively

```bash
# View all installed moreutils tools
dpkg -L moreutils

# Read documentation
man sponge
man combine
```

### [tldr](https://github.com/tldr-pages/tldr) - Simplified Command Examples

`tldr` provides simple, practical examples for command-line tools (community-driven alternative to traditional man pages):

```bash
# Get quick examples for a command
tldr tar

# Update tldr database
tldr --update

# Search for commands (for it to work requires previous --update)
tldr --list | grep network
```

### [bat](https://github.com/sharkdp/bat) - Syntax-Highlighted File Viewer

`bat` is a `cat` clone with syntax highlighting and Git integration:

```bash
# View a file with syntax highlighting (bat is aliased to batcat)
bat script.py

# View with line numbers
bat -n config.json

# Show non-printable characters
bat -A file.txt

# View multiple files
bat src/*.rs

# Page through long files automatically
bat large-log.txt

# Compare with cat (plain output)
batcat --paging=never file.py
```

> **Note**: The script aliases `cat` to `batcat --theme=Coldark-Cold --paging=never` for everyday use.

### [jq](https://jqlang.github.io/jq/) - JSON Processor

`jq` is a lightweight command-line JSON processor:

```bash
# Pretty-print JSON
echo '{"name":"Alice","age":30}' | jq '.'

# Extract a specific field
curl -s https://api.github.com/users/github | jq '.name'

# Filter array elements
echo '[{"name":"Alice","age":30},{"name":"Bob","age":25}]' | jq '.[] | select(.age > 26)'

# Get all keys from an object
echo '{"a":1,"b":2,"c":3}' | jq 'keys'

# Transform data
echo '{"first":"John","last":"Doe"}' | jq '{fullname: "\(.first) \(.last)"}'

# Work with files
jq '.users[].email' data.json

# Combine with other tools
cat package.json | jq '.dependencies' | grep -i react
```

### [yq](https://github.com/mikefarah/yq) - YAML/TOML/XML Processor

`yq` is like `jq` but for YAML, TOML, XML, and other formats:

```bash
# Pretty-print YAML
yq '.' config.yaml

# Extract a field
yq '.services.web.image' docker-compose.yml

# Convert YAML to JSON
yq -o=json '.' config.yaml

# Convert JSON to YAML
yq -P '.' data.json

# Update a value in-place
yq -i '.version = "2.0"' config.yaml

# Read TOML files
yq -p=toml '.' pyproject.toml
```

### Arrow Key History Search

The shell is configured with incremental history search using the up/down arrow keys. Simply type the beginning of a command and press the up arrow to search backward through commands that start with what you've typed, or down arrow to search forward.

```bash
# Type a command prefix, then press up/down arrows
git  # Press up arrow to cycle through commands starting with 'git'
cd   # Press up arrow to find previous 'cd' commands
```

It's a fast way back to recent commands without opening a full search UI. For filtering and a visual interface, use hstr (see below).

### [hstr](https://github.com/dvorka/hstr) - Enhanced History Search

`hstr` provides better command history navigation (configured with `Ctrl+R`):

```bash
# Press Ctrl+R to launch interactive history search
# Type to filter commands, use arrows to navigate

# Or use the h alias
h

# Search for specific pattern
hstr docker

# Configuration in .zshrc provides:
# - Ctrl+R: Interactive history search with filtering
# - Visual highlighting of search results
# - Better than default Ctrl+R search
```

**Video Tutorials**:
- [Dvorka's Demo](https://www.youtube.com/watch?v=sPF29NyXe2U) - Demonstration by the creator
- [Zack's Tutorial](https://www.youtube.com/watch?v=Qd75pIeQkH8) - User tutorial
- [Yu-Jie Lin's Presentation](https://www.youtube.com/watch?v=Qx5n_5B5xUw) - Feature showcase

### [unp](https://packages.debian.org/trixie/unp) - Universal Unpacker

`unp` extracts many archive formats, automatically picking the right extraction tool for each:

```bash
# Extract any archive type
unp archive.zip
unp tarball.tar.gz
unp file.rar
unp data.7z

# Supported formats: zip, tar.gz, tar.bz2, tar.xz, deb, and more.
# rar/7z/rpm need the matching backend tool installed (p7zip, unrar, rpm2cpio).
```

### [httpie](https://httpie.io/) - User-Friendly HTTP Client

`httpie` is a friendlier alternative to `curl`. JSON is the default request body, responses come back colorized, and the syntax is easier to remember:

```bash
# Simple GET request (auto-formats JSON response)
http https://api.github.com/users/github

# GET request with query parameters
http GET https://httpbin.org/get search==httpie lang==en

# POST request with JSON data (JSON is the default)
http POST https://httpbin.org/post name=Alice email=alice@example.com

# POST with explicit JSON
http POST https://api.example.com/users name=Bob age:=25 active:=true

# Custom headers
http GET https://api.example.com/data Authorization:"Bearer TOKEN" User-Agent:CustomClient

# Download a file
http --download https://example.com/file.zip

# Basic authentication
http -a username:password https://api.example.com/secure

# Form data (instead of JSON)
http --form POST https://httpbin.org/post name=Alice file@document.pdf

# Upload JSON file
http POST https://api.example.com/data < data.json

# Pretty-print an existing JSON file (build the request offline, don't send it)
http --print=B --pretty=all --offline < messy.json

# Follow redirects
http --follow https://example.com/redirect

# Show request and response headers
http --verbose GET https://httpbin.org/headers

# Session support (saves cookies and auth)
http --session=./session.json https://api.example.com/login username=alice password=secret
http --session=./session.json https://api.example.com/profile
```

### [ncdu](https://dev.yorhel.nl/ncdu) - Disk Usage Analyzer

`ncdu` provides an interactive disk usage analyzer:

```bash
# Analyze current directory
ncdu

# Analyze specific directory
ncdu /var

# Use a color scheme tuned for dark terminals
ncdu --color dark /home

# Export results to file
ncdu -o diskusage.json

# Navigate with arrow keys:
#   Up/Down: Navigate items
#   Right/Enter: Open directory
#   Left: Go to parent directory
#   d: Delete selected file/directory
#   g: Show percentage and/or graph
#   q: Quit
```

### [uv](https://github.com/astral-sh/uv) - Fast Python Package Manager

`uv` is a Python package installer and resolver written in Rust. Astral, its maker, benchmarks it at 10-100x faster than pip:

```bash
uv --help

# Virtual environment management
uv venv .venv
source .venv/bin/activate
uv pip install flask

# Run Python tools without installing (uvx is shorthand for uv tool run)
uv tool run ruff                      # Run tool without parameters
uv tool run --from httpie http httpbin.org/get  # Run with parameters (httpie's command is `http`)
uv tool run git+https://github.com/astral-sh/ruff  # Run tool directly from Git

# Install tools globally
uv tool install ruff

# Install tools directly from git repositories
uv tool install git+https://github.com/astral-sh/ruff

# Install from specific branch or commit
uv tool install git+https://github.com/user/tool@main

# Other useful commands
uv pip compile requirements.in -o requirements.txt  # Pin dependencies
uv pip sync requirements.txt                         # Match requirements exactly
uv pip list --outdated                               # Check for updates
```

### [fzf](https://github.com/junegunn/fzf) - Fuzzy Finder

`fzf` is a general-purpose command-line fuzzy finder:

```bash
# Search files in current directory
fzf

# Preview files while searching
fzf --preview 'batcat --color=always {}'

# Search command history
history | fzf

# Fuzzy find and open in editor
vim $(fzf)

# Search running processes
ps aux | fzf

# Search and kill process
kill -9 $(ps aux | fzf | awk '{print $2}')

# Multi-select files (Tab to select, Enter to confirm)
rm $(fzf --multi)
```

> **Note**: The `cd` command is replaced by `zoxide` for smart frecency-based directory navigation.

### [zoxide](https://github.com/ajeetdsouza/zoxide) - Smart Directory Navigation

`zoxide` is a smarter cd command that tracks your most frequently and recently used directories:

```bash
# After using zoxide for a while, jump to directories by partial name
cd doc      # cd to ~/Documents if that's your highest ranking match
cd ~/pro    # cd to ~/projects
cd foo bar  # cd into highest ranked directory matching foo and bar
cd ..       # Works like normal cd

# View zoxide's database
zoxide query --list

# Remove a directory from the database
zoxide remove /path/to/dir
```

### Shell Helper Functions

The script provides convenient shell functions for common directory operations:

```bash
# mkcd - Create directory and cd into it
mkcd ~/new/project/path
# Equivalent to: mkdir -p ~/new/project/path && cd ~/new/project/path

# tempe - Create temporary directory and cd into it
tempe
# Creates a temp dir with 700 permissions and navigates to it

# tempe with subdirectory
tempe mywork
# Creates temp dir, then creates and enters 'mywork' subdirectory
```

### [eget](https://github.com/zyedidia/eget) - Easy Binary Installation

eget is a tool that makes it easy to install pre-built binaries from GitHub releases:

```bash
eget --help

# Install tools from GitHub releases
eget neovim/neovim

# Install specific version
eget zyedidia/micro --tag nightly

# Install to specific location
eget jgm/pandoc --to /usr/local/bin

# Filter assets by substring (^ = anti-match; here skip musl builds)
eget eza-community/eza --asset ^musl

# Install for specific system
eget --system darwin/amd64 sharkdp/fd

# Download from direct URL
eget https://go.dev/dl/go1.17.5.linux-amd64.tar.gz --file go --to ~/go1.17.5
```

### [gitsnip](https://github.com/dagimg-dot/gitsnip) - Download Specific Folders from Git Repositories

gitsnip allows you to download specific folders from any Git repository without cloning the entire repo:

```bash
# Basic usage: gitsnip <repo-url> <subdir> <output-dir>
# Download a specific folder from a public repository (default method is sparse checkout)
gitsnip https://github.com/user/repo src/components ./my-components

# Download from specific branch
gitsnip https://github.com/user/repo docs ./docs -b develop

# Use API method instead of sparse checkout
gitsnip https://github.com/user/repo src/utils ./utils -m api

# Download from private repository (requires GitHub token)
gitsnip https://github.com/user/private-repo config ./config -t YOUR_GITHUB_TOKEN
```

### [lazygit](https://github.com/jesseduffield/lazygit) - Terminal UI for Git Commands

lazygit is a terminal UI for git. It's especially handy for the clumsy operations, like partial staging and interactive rebase:

```bash
# Launch lazygit in current repository
lazygit

# Create convenient alias (add to .zshrc)
echo "alias lg='lazygit'" >> ~/.zshrc

# Advanced: Change directory on exit
# Use EITHER the alias above OR this lg() function, not both - a shell alias named lg
# shadows a same-named function, so the alias would win and the cd-on-exit never runs.
# If you change repos in lazygit and want your shell to follow it on exit, add this to ~/.zshrc:
lg()
{
    export LAZYGIT_NEW_DIR_FILE=~/.lazygit/newdir
    lazygit "$@"
    if [ -f $LAZYGIT_NEW_DIR_FILE ]; then
            cd "$(cat $LAZYGIT_NEW_DIR_FILE)"
            rm -f $LAZYGIT_NEW_DIR_FILE > /dev/null
    fi
}
```

**Key Features**:
- **Stage individual lines** - Partial staging with intuitive interface
- **Interactive rebase** - Squash, fixup, drop, edit, reorder commits visually
- **Cherry-pick** - Visual cherry-picking of commits
- **Amend old commits** - Fix commits deep in history
- **Undo/Redo** - Easy mistake recovery
- **Commit graph** - Visualize branch structure
- **Git worktrees** - Manage multiple working trees
- **Custom commands** - Define your own keybindings
- **Rebase magic** - Create custom patches interactively

**Common Keyboard Shortcuts** (inside lazygit):
- `Space` - Stage/unstage files or hunks
- `a` - Stage/unstage all
- `c` - Commit changes
- `P` - Push
- `p` - Pull
- `e` - Edit file
- `o` - Open file
- `s` - Stash changes
- `i` - Start interactive rebase
- `R` - Refresh
- `?` - Show keybindings help

**Documentation**:
- [GitHub Repository](https://github.com/jesseduffield/lazygit)
- [Configuration Guide](https://github.com/jesseduffield/lazygit/blob/master/docs/Config.md)
- [Keybindings Reference](https://github.com/jesseduffield/lazygit/blob/master/docs/keybindings)
- [Undo/Redo Documentation](https://github.com/jesseduffield/lazygit/blob/master/docs/Undoing.md)

**Official Video Tutorials**:
- [15 Lazygit Features in 15 Minutes](https://youtu.be/CPLdltN7wgE) - Quick feature overview
- [Basics Tutorial](https://youtu.be/VDXvbHZYeKY) - Getting started guide

### [lazydocker](https://github.com/jesseduffield/lazydocker) - Terminal UI for Docker

lazydocker is a terminal UI for docker and docker-compose. Container status, logs, and stats all live on one screen:

```bash
# Launch lazydocker
lazydocker

# Create convenient alias (add to .zshrc)
echo "alias lzd='lazydocker'" >> ~/.zshrc
```

**Key Features**:
- **Container overview** - View all containers and services at a glance
- **Real-time logs** - Stream logs from containers with color coding
- **Metrics graphs** - ASCII graphs of CPU, memory, and network usage
- **Quick actions** - Restart, remove, rebuild containers with single keys
- **Image management** - View image layers and ancestry
- **Pruning** - Clean up unused containers, images, and volumes
- **Mouse support** - Click to navigate (optional)
- **Custom commands** - Define your own shortcuts
- **docker-compose support** - Full integration with compose services

**Common Keyboard Shortcuts** (inside lazydocker):
- `[` / `]` - Previous / next tab in the main view (logs, stats, config)
- `1`-`6` - Focus the projects / containers / images / volumes / networks panels
- `m` - View container logs
- `s` - Stop container
- `r` - Restart container
- `p` - Pause container
- `E` - Execute shell in container
- `d` - Remove container
- `b` - Bulk commands menu (includes prune / remove-all)
- `c` - Run a predefined custom command (`X` for a one-off global command)
- `?` - Show keybindings help

**Documentation**:
- [GitHub Repository](https://github.com/jesseduffield/lazydocker)
- [Configuration Guide](https://github.com/jesseduffield/lazydocker/blob/master/docs/Config.md)
- [Keybindings Reference](https://github.com/jesseduffield/lazydocker/blob/master/docs/keybindings)

**Official Video Tutorials**:
- [Demo & Basic Tutorial](https://youtu.be/NICqQPxwJWw) - Introduction and walkthrough

## Configuration Files

The script creates/modifies these configuration files:

**Shell & Terminal:**
- `~/.zshrc` - Enhanced Zsh configuration with custom aliases and integrations
- `~/.config/terminator/config` - Terminator terminal settings
- `~/.config/terminator/plugins/tab_numbers.py` - Tab numbers plugin for Terminator
- `~/.config/gtk-3.0/gtk.css` - GTK terminal padding configuration (8px)

**Desktop Environment (XFCE):**
- `~/.config/xfce4/helpers.rc` - Default terminal application settings
- `~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml` - Screensaver & lock screen (both disabled)
- `~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml` - Display power management / DPMS (disabled)
- `~/.config/xfce4/xfconf/xfce-perchannel-xml/keyboard-layout.xml` - Keyboard layout (German)

**Supply-Chain Hardening (user-level):**
- `~/.npmrc` - npm security hardening (ignore-scripts, save-exact, min-release-age)
- `~/.bunfig.toml` - Bun security hardening (exact versions, minimum release age)
- `~/.cargo/config.toml` - Cargo security hardening (git-fetch-with-cli)
- `~/.config/uv/uv.toml` - uv security hardening (exclude-newer, system-certs)
- `~/.config/pip/pip.conf` - pip security hardening (prefer-binary)

**Supply-Chain Hardening (system-level fallbacks):**
- `/usr/local/etc/npmrc` - npm fallback (mirrors user config)
- `/etc/uv/uv.toml` - uv fallback (mirrors user config)
- `/etc/pip.conf` - pip fallback (mirrors user config)

**System Configuration:**
- `/etc/systemd/resolved.conf.d/disable-stub.conf` - DNS stub listener configuration
- `/etc/apt/sources.list.d/docker.list` - Docker CE repository
- `/etc/apt/sources.list.d/vscode.sources` - Visual Studio Code repository

**Runtime Environments (Conditional):**
- `~/.cargo/env` - Rust/Cargo environment (if installed via rustup)
- `~/.rustup/` - Rust toolchain directory (if installed via rustup)
- `~/.bun/` - Bun runtime and package manager directory

## Security Considerations

- **No root execution**: Script refuses to run as root for security
- **User verification**: Prompts before making system changes
- **Sandboxed tools**: Includes bubblewrap for command isolation
- **Docker security**: User added to docker group (requires logout)
- **Supply-chain hardening** (all configs consolidated in `apply_supply_chain_hardening()`, runnable standalone via `--harden-only`):
  - npm: `ignore-scripts=true`, `save-exact=true`, 7-day `min-release-age` quarantine
  - Bun: exact version pinning, 7-day `minimumReleaseAge`, text lockfiles
  - pip: `prefer-binary=true` (prefers prebuilt wheels, reducing - not eliminating - execution of untrusted `setup.py`)
  - uv: `exclude-newer` 1-week quarantine, `system-certs` (system CA store), system Python preference
  - Go: `GOPROXY=https://proxy.golang.org,off`, `GOSUMDB=sum.golang.org` (checksum verification)
  - Cargo: `git-fetch-with-cli` (uses system git instead of libgit2), `--locked` on all installs
  - curl: `--proto '=https' --tlsv1.2` enforced on all remote script downloads
  - System-level fallback configs (`/usr/local/etc/npmrc`, `/etc/pip.conf`, `/etc/uv/uv.toml`) for defence-in-depth

## Compatibility

| Distribution | Status | Notes |
|-------------|---------|-------|
| Kali Linux  | ✅ Full support | All features enabled |
| Debian      | ✅ Compatible | Pentesting tools skipped. Tested: 12, 13 |
| Ubuntu      | ✅ Compatible | Pentesting tools skipped. Tested: 22.04 LTS, 24.04 LTS |
| Other Debian-based | ⚠️ May work | Not tested |

## Tools Reference

Every tool the script installs, with links to its homepage and docs.

### Core System Tools

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **build-essential** | [Debian Package](https://packages.debian.org/trixie/build-essential) | [man pages](https://manpages.debian.org/) |
| **curl** | [curl.se](https://curl.se/) | [Documentation](https://curl.se/docs/) |
| **wget** | [GNU Wget](https://www.gnu.org/software/wget/) | [Manual](https://www.gnu.org/software/wget/manual/) |
| **git** | [git-scm.com](https://git-scm.com/) | [Documentation](https://git-scm.com/doc) |
| **htop** | [htop.dev](https://htop.dev/) | [man page](https://www.man7.org/linux/man-pages/man1/htop.1.html) |
| **lsof** | [lsof](https://github.com/lsof-org/lsof) | [man page](https://man7.org/linux/man-pages/man8/lsof.8.html) |
| **ncdu** | [ncdu](https://dev.yorhel.nl/ncdu) | [man page](https://dev.yorhel.nl/ncdu/man) |
| **tree** | [GitLab](https://gitlab.com/OldManProgrammer/unix-tree) | [man page](https://linux.die.net/man/1/tree) |
| **unp** | [Debian Package](https://packages.debian.org/trixie/unp) | [man page](https://manpages.debian.org/trixie/unp/unp.1.en.html) |
| **exiftool** | [exiftool.org](https://exiftool.org/) | [Documentation](https://exiftool.sourceforge.net/exiftool_pod.html) |
| **ufw** | [UFW](https://launchpad.net/ufw) | [man page](https://manpages.ubuntu.com/manpages/noble/man8/ufw.8.html) |

### Modern CLI Alternatives

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **ripgrep (rg)** | [GitHub](https://github.com/BurntSushi/ripgrep) | [User Guide](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md) |
| **fd (fd-find)** | [GitHub](https://github.com/sharkdp/fd) | [README](https://github.com/sharkdp/fd#how-to-use) |
| **sd** | [GitHub](https://github.com/chmln/sd) | [README](https://github.com/chmln/sd#quick-examples) |
| **bat** | [GitHub](https://github.com/sharkdp/bat) | [README](https://github.com/sharkdp/bat#usage) |
| **fzf** | [GitHub](https://github.com/junegunn/fzf) | [README](https://github.com/junegunn/fzf#usage) |
| **jq** | [jqlang.github.io](https://jqlang.github.io/jq/) | [Manual](https://jqlang.github.io/jq/manual/) |
| **moreutils** | [joeyh.name](https://joeyh.name/code/moreutils/) | [man pages](https://manpages.debian.org/trixie/moreutils/) |
| **httpie** | [httpie.io](https://httpie.io/) | [Documentation](https://httpie.io/docs/cli) |
| **name-that-hash** | [GitHub](https://github.com/HashPals/Name-That-Hash) | [README](https://github.com/HashPals/Name-That-Hash#usage) |
| **tldr** | [GitHub](https://github.com/tldr-pages/tldr) | [Documentation](https://github.com/tldr-pages/tldr#how-do-i-use-it) |
| **eget** | [GitHub](https://github.com/zyedidia/eget) | [Documentation](https://github.com/zyedidia/eget/blob/master/DOCS.md) |
| **gitsnip** | [GitHub](https://github.com/dagimg-dot/gitsnip) | [README](https://github.com/dagimg-dot/gitsnip#readme) |
| **delta** | [GitHub](https://github.com/dandavison/delta) | [Manual](https://dandavison.github.io/delta/) |
| **yq** | [GitHub](https://github.com/mikefarah/yq) | [Documentation](https://mikefarah.gitbook.io/yq) |

### Shell & Terminal

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **zsh** | [zsh.org](https://www.zsh.org/) | [Documentation](https://zsh.sourceforge.io/Doc/) |
| **hstr** | [GitHub](https://github.com/dvorka/hstr) | [README](https://github.com/dvorka/hstr#usage) |
| **zoxide** | [GitHub](https://github.com/ajeetdsouza/zoxide) | [README](https://github.com/ajeetdsouza/zoxide#readme) |
| **up** | [GitHub](https://github.com/akavel/up) | [README](https://github.com/akavel/up#usage) |
| **lazygit** | [GitHub](https://github.com/jesseduffield/lazygit) | [Documentation](https://github.com/jesseduffield/lazygit#readme) |
| **terminator** | [terminator-gtk3](https://gnome-terminator.org/) | [Documentation](https://gnome-terminator.readthedocs.io/) |

### Programming Languages & Runtimes

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **Python 3** | [python.org](https://www.python.org/) | [Documentation](https://docs.python.org/3/) |
| **Go (golang)** | [go.dev](https://go.dev/) | [Documentation](https://go.dev/doc/) |
| **Rust (rustc)** | [rust-lang.org](https://www.rust-lang.org/) | [Documentation](https://doc.rust-lang.org/) |
| **Cargo** | [doc.rust-lang.org](https://doc.rust-lang.org/cargo/) | [Book](https://doc.rust-lang.org/cargo/index.html) |
| **Bun** | [bun.sh](https://bun.sh/) | [Documentation](https://bun.sh/docs) |

### Python Package Managers & Tools

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **pipx** | [GitHub](https://github.com/pypa/pipx) | [Documentation](https://pipx.pypa.io/stable/) |
| **uv** | [GitHub](https://github.com/astral-sh/uv) | [Documentation](https://docs.astral.sh/uv/) |

### Containerization & Security

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **Docker CE** | [docker.com](https://www.docker.com/) | [Documentation](https://docs.docker.com/) |
| **lazydocker** | [GitHub](https://github.com/jesseduffield/lazydocker) | [Documentation](https://github.com/jesseduffield/lazydocker#readme) |
| **ufw-docker** | [GitHub](https://github.com/chaifeng/ufw-docker) | [README](https://github.com/chaifeng/ufw-docker#ufw-docker) |
| **bubblewrap** | [GitHub](https://github.com/containers/bubblewrap) | [man page](https://github.com/containers/bubblewrap#bubblewrap) |

### GUI Applications (Only Installed When GUI Detected)

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **gedit** | [gedit-text-editor.org](https://gedit-text-editor.org/) | [Help](https://gedit-text-editor.org/documentation.html) |
| **meld** | [meldmerge.org](https://meldmerge.org/) | [Help](https://meldmerge.org/) |
| **Visual Studio Code** | [code.visualstudio.com](https://code.visualstudio.com/) | [Docs](https://code.visualstudio.com/docs) |
| **xsel** | [GitHub](https://github.com/kfish/xsel) | [man page](https://linux.die.net/man/1/xsel) |
| **Fira Code Font** | [GitHub](https://github.com/tonsky/FiraCode) | [README](https://github.com/tonsky/FiraCode#fira-code-monospaced-font-with-programming-ligatures) |

### Kali Linux Specific Tools (Only Installed on Kali)

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **massdns** | [GitHub](https://github.com/blechschmidt/massdns) | [README](https://github.com/blechschmidt/massdns#usage) |
| **mitmproxy** | [mitmproxy.org](https://mitmproxy.org/) | [Documentation](https://docs.mitmproxy.org/stable/) |
| **pdtm** | [GitHub](https://github.com/projectdiscovery/pdtm) | [README](https://github.com/projectdiscovery/pdtm#usage) |
| **ProjectDiscovery Tools** | [projectdiscovery.io](https://projectdiscovery.io/) | [Documentation](https://docs.projectdiscovery.io/) |
| **bbot** | [GitHub](https://github.com/blacklanternsecurity/bbot) | [Documentation](https://www.blacklanternsecurity.com/bbot/) |
| **NetExec** | [GitHub](https://github.com/Pennyw0rth/NetExec) | [Wiki](https://github.com/Pennyw0rth/NetExec/wiki) |
| **BloodHoundAnalyzer** | [GitHub](https://github.com/c0ffee0wl/BloodHoundAnalyzer) | [README](https://github.com/c0ffee0wl/BloodHoundAnalyzer) |

## Troubleshooting

### Common Issues

**Script fails with permission errors:**
```bash
# Ensure user has sudo privileges
sudo -l
```

**Docker commands fail after installation:**
```bash
# Log out and back in, or run:
newgrp docker
```

**Zsh not set as default shell:**
```bash
chsh -s /usr/bin/zsh
```

### Debug Mode
Run with verbose output:
```bash
bash -x ./linux-setup.sh
```

## Customization

The script can be modified for different environments:

1. **Package selection**: Edit the package list in the script
2. **Shell configuration**: Modify the `.zshrc` template
3. **Terminal setup**: Adjust Terminator configuration
4. **Tool selection**: Comment out unwanted tool installations

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test on multiple distributions
4. Submit a pull request

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Builds on Kali's default zsh and Terminator configs
- Bundles tools from the open-source CLI community (ripgrep, fzf, zoxide, lazygit, and more)

---

**⚠️ Important**: Always review scripts before execution. This script makes system-wide changes and should be tested in a virtual machine first.
