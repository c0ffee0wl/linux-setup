# Linux Setup Script

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Overview](#overview)
- [Requirements](#requirements)
- [Installation](#installation)
  - [Quick Start](#quick-start)
  - [What the script does:](#what-the-script-does)
- [Post-Installation](#post-installation)
- [Usage Examples](#usage-examples)
  - [Basic Shell Operations Previewed in Ultimate Plumber](#basic-shell-operations-previewed-in-ultimate-plumber)
  - [ripgrep (rg) - Fast Recursive Search](#ripgrep-rg---fast-recursive-search)
  - [sd - Search & Displace (sed replacement)](#sd---search--displace-sed-replacement)
  - [fd - Fast File Finder](#fd---fast-file-finder)
  - [moreutils - Advanced Unix Tools](#moreutils---advanced-unix-tools)
- [Configuration Files](#configuration-files)
- [Security Considerations](#security-considerations)
- [Compatibility](#compatibility)
- [Features](#features)
  - [Development Tools](#development-tools)
  - [Containerization](#containerization)
  - [Terminal & Shell](#terminal--shell)
  - [Productivity Tools](#productivity-tools)
  - [System Configuration](#system-configuration)
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

A comprehensive automation script for setting up a fresh Debian/Kali Linux installation with development tools, terminal enhancements, and security-focused configurations.

## Overview

This script configures a fresh Debian-based Linux system (optimized for Kali Linux) with essential development tools, modern terminal utilities, and productivity enhancements. It's designed for security professionals, developers, and power users who want a consistent, well-configured Linux environment.

## Requirements

- **OS**: Debian-based Linux distribution (Ubuntu, Debian, Kali Linux)
- **User**: Non-root user with sudo privileges
- **Network**: Internet connection for package downloads
- **Storage**: ~2GB free space for all tools and dependencies

## Installation

### Quick Start
```bash
git clone https://github.com/c0ffee0wl/linux-setup.git
cd linux-setup
./linux-setup.sh
```

### What the script does:
1. **System verification**: Checks OS compatibility and user privileges
2. **Package updates**: Updates system packages and repositories  
3. **Tool installation**: Installs all development and productivity tools
4. **Configuration**: Sets up shell, terminal, and system preferences
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
   ```

## Usage Examples

This section demonstrates practical usage of the installed tools with real-world examples.

### Basic Shell Operations Previewed in Ultimate Plumber

Classic Unix command pipelines with `awk`, `cut`, and `sed`, previewed with [up - the Ultimate Plumber](https://github.com/akavel/up), safely [bubblewrapped](https://github.com/containers/bubblewrap) in a sandbox.

```bash
# Toggle between command and result with Ctrl+P (up tool integration)
cat users.txt |    # Press Ctrl+P to interactively build the pipeline
# Press Ctrl+X when satisied with the sandboxed preview to actually execute

# Process user data: extract field, trim path, remove header/footer
cat users.txt | awk '{print $5}' | cut -d '/' -f2 | sed '1,2d; $d'

# Sandboxed shell execution with bubblewrap
polster sh         # Isolated, restricted shell environment
```

### ripgrep (rg) - Fast Recursive Search

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
#   -u, -uu, -uuu: unrestricted searching (gitignored, hidden, binary files)
#   -l: list files matching
#   -e: pattern (regex) to search for
#   -o: show only matching fragment
```

### sd - Search & Displace (sed replacement)

```bash
# Simple text replacement
sd "horse" "Pferd" ad/GOAD/data/config.json

# Pipeline usage - replace newlines with commas
cat ~/users.txt | sd '\n' ',' | tail

# Extract path components with regex capture groups
echo "sample with /path/" | sd '.*(/.*/)' '$1'
```

### fd - Fast File Finder

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

### moreutils - Advanced Unix Tools

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

# WARNING: sponge buffers entire output in memory before writing!
# Be careful with large files or long-running commands.
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

## Configuration Files

The script creates/modifies these configuration files:
- `~/.zshrc` - Enhanced Zsh configuration
- `~/.config/terminator/config` - Terminator terminal settings
- `~/.config/xfce4/helpers.rc` - Default application settings
- Various Xfce power management settings

## Security Considerations

- **No root execution**: Script refuses to run as root for security
- **User verification**: Prompts before making system changes
- **Sandboxed tools**: Includes bubblewrap for command isolation
- **Docker security**: User added to docker group (requires logout)

## Compatibility

| Distribution | Status | Notes |
|-------------|---------|-------|
| Kali Linux  | ✅ Full support | All features enabled |
| Debian      | ✅ Compatible | Pentesting tools skipped |
| Ubuntu      | ✅ Compatible | Pentesting tools skipped |
| Other Debian-based | ⚠️ May work | Limited testing |

## Features

### Development Tools
- **Build essentials**: gcc, make, build tools
- **Languages**: Go, Rust/Cargo, Python 3 with pip
- **Package managers**: uv (modern Python package installer)

### Containerization
- **Docker CE**: Latest Docker Community Edition
- **User configuration**: Automatic docker group membership
- **Service management**: Auto-start Docker daemon

### Terminal & Shell
- **Shell**: Zsh with enhanced configuration based on Kali defaults
- **Terminal**: Terminator as default with custom configuration
- **History**: Enhanced history management with HSTR integration
- **Navigation**: enhancd for intelligent directory jumping
- **Search tools**: ripgrep, fd-find, fzf for fast file operations

### Productivity Tools
- **File management**: tree, meld for directory visualization and file comparison  
- **Text processing**: sd (sed alternative), moreutils
- **Interactive tools**: up tool for live command building
- **Security sandboxing**: bubblewrap for isolated command execution

### System Configuration
- **Power management**: Disabled screensaver and power saving
- **Keyboard**: German layout configuration
- **Display**: Optimized for development workflow
- **Security**: User-level execution (no root required)

## Tools Reference

This section provides a comprehensive reference of all tools installed by the script, including links to their documentation and availability information.

### Core System Tools

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **build-essential** | [Debian Package](https://packages.debian.org/bookworm/build-essential) | [man pages](https://manpages.debian.org/) |
| **curl** | [curl.se](https://curl.se/) | [Documentation](https://curl.se/docs/) |
| **wget** | [GNU Wget](https://www.gnu.org/software/wget/) | [Manual](https://www.gnu.org/software/wget/manual/) |
| **git** | [git-scm.com](https://git-scm.com/) | [Documentation](https://git-scm.com/doc) |
| **htop** | [htop.dev](https://htop.dev/) | [man page](https://www.man7.org/linux/man-pages/man1/htop.1.html) |
| **lsof** | [lsof](https://github.com/lsof-org/lsof) | [man page](https://man7.org/linux/man-pages/man8/lsof.8.html) |
| **ncdu** | [ncdu](https://dev.yorhel.nl/ncdu) | [man page](https://dev.yorhel.nl/ncdu/man) |
| **tree** | [tree](http://mama.indstate.edu/users/ice/tree/) | [man page](https://linux.die.net/man/1/tree) |
| **unp** | [unp](https://github.com/mitsuhiko/unp) | [GitHub](https://github.com/mitsuhiko/unp) |
| **exiftool** | [exiftool.org](https://exiftool.org/) | [Documentation](https://exiftool.org/exiftool_pod.html) |
| **ufw** | [UFW](https://launchpad.net/ufw) | [man page](https://manpages.ubuntu.com/manpages/focal/man8/ufw.8.html) |

### Modern CLI Alternatives

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **ripgrep (rg)** | [GitHub](https://github.com/BurntSushi/ripgrep) | [User Guide](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md) |
| **fd (fd-find)** | [GitHub](https://github.com/sharkdp/fd) | [README](https://github.com/sharkdp/fd#how-to-use) |
| **sd** | [GitHub](https://github.com/chmln/sd) | [README](https://github.com/chmln/sd#quick-examples) |
| **bat** | [GitHub](https://github.com/sharkdp/bat) | [README](https://github.com/sharkdp/bat#usage) |
| **fzf** | [GitHub](https://github.com/junegunn/fzf) | [README](https://github.com/junegunn/fzf#usage) |
| **jq** | [jqlang.github.io](https://jqlang.github.io/jq/) | [Manual](https://jqlang.github.io/jq/manual/) |
| **moreutils** | [joeyh.name](https://joeyh.name/code/moreutils/) | [man pages](https://linux.die.net/man/1/moreutils) |

### Shell & Terminal

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **zsh** | [zsh.org](https://www.zsh.org/) | [Documentation](https://zsh.sourceforge.io/Doc/) |
| **hstr** | [GitHub](https://github.com/dvorka/hstr) | [README](https://github.com/dvorka/hstr#usage) |
| **enhancd** | [GitHub](https://github.com/babarot/enhancd) | [README](https://github.com/babarot/enhancd#features) |
| **up** | [GitHub](https://github.com/akavel/up) | [README](https://github.com/akavel/up#usage) |
| **terminator** | [terminator-gtk3](https://gnome-terminator.org/) | [Documentation](https://gnome-terminator.readthedocs.io/) |

### Programming Languages & Runtimes

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **Python 3** | [python.org](https://www.python.org/) | [Documentation](https://docs.python.org/3/) |
| **Go (golang)** | [go.dev](https://go.dev/) | [Documentation](https://go.dev/doc/) |
| **Rust (rustc)** | [rust-lang.org](https://www.rust-lang.org/) | [Documentation](https://doc.rust-lang.org/) |
| **Cargo** | [doc.rust-lang.org](https://doc.rust-lang.org/cargo/) | [Book](https://doc.rust-lang.org/cargo/index.html) |
| **Node.js** | [nodejs.org](https://nodejs.org/) | [Documentation](https://nodejs.org/docs/latest/api/) |
| **npm** | [npmjs.com](https://www.npmjs.com/) | [Documentation](https://docs.npmjs.com/) |

### Python Package Managers & Tools

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **pipx** | [GitHub](https://github.com/pypa/pipx) | [Documentation](https://pipx.pypa.io/stable/) |
| **uv** | [GitHub](https://github.com/astral-sh/uv) | [Documentation](https://docs.astral.sh/uv/) |
| **httpie** | [httpie.io](https://httpie.io/) | [Documentation](https://httpie.io/docs/cli) |
| **name-that-hash** | [GitHub](https://github.com/HashPals/Name-That-Hash) | [README](https://github.com/HashPals/Name-That-Hash#usage) |

### Containerization & Security

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **Docker CE** | [docker.com](https://www.docker.com/) | [Documentation](https://docs.docker.com/) |
| **ufw-docker** | [GitHub](https://github.com/chaifeng/ufw-docker) | [README](https://github.com/chaifeng/ufw-docker#ufw-docker) |
| **bubblewrap** | [GitHub](https://github.com/containers/bubblewrap) | [man page](https://github.com/containers/bubblewrap#bubblewrap) |

### GUI Applications (Only Installed When GUI Detected)

| Tool | Homepage | Documentation |
|------|----------|---------------|
| **gedit** | [GNOME](https://wiki.gnome.org/Apps/Gedit) | [Help](https://help.gnome.org/users/gedit/stable/) |
| **meld** | [meldmerge.org](https://meldmerge.org/) | [Help](https://meldmerge.org/) |
| **Visual Studio Code** | [code.visualstudio.com](https://code.visualstudio.com/) | [Docs](https://code.visualstudio.com/docs) |
| **xsel** | [xsel](http://www.vergenet.net/~conrad/software/xsel/) | [man page](https://linux.die.net/man/1/xsel) |
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

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Based on Kali Linux default configurations
- Inspired by modern terminal and shell enhancements

---

**⚠️ Important**: Always review scripts before execution. This script makes system-wide changes and should be tested in a virtual machine first.
