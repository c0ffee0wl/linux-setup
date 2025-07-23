# Linux Setup Script

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
chmod +x linux-setup.sh
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
| Debian      | ✅ Compatible | massdns and pdtm tools skipped |
| Ubuntu      | ✅ Compatible | massdns and pdtm tools skipped |
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

### Kali Linux Specific (when detected)
- **DNS tools**: massdns for subdomain enumeration
- **Security toolkit**: Project Discovery tools via pdtm
- **Reconnaissance**: Complete pentesting tool installation

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
