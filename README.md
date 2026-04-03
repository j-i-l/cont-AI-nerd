# cont[AI]*nerd*

**Sandboxed AI coding agent powered by [OpenCode](https://opencode.ai), running in a rootful Podman container with file system isolation and automatic change tracking.**

cont-AI-nerd provides a secure, containerized environment for running an AI coding assistant that can read and write files in your project directories while maintaining strict isolation from the rest of your system.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Installation](#installation)
   - [Quick Start](#quick-start)
   - [Step 1: Clone the Repository](#step-1-clone-the-repository)
   - [Step 2: Configure](#step-2-configure)
   - [Step 3: Setup](#step-3-setup)
5. [Usage](#usage)
   - [Starting the TUI](#starting-the-tui)
   - [Monitoring](#monitoring)
   - [Viewing Logs](#viewing-logs)
6. [Configuration Reference](#configuration-reference)
7. [How It Works](#how-it-works)
   - [Container Isolation](#container-isolation)
   - [File Permissions Model](#file-permissions-model)
   - [Systemd Services](#systemd-services)
   - [Automatic Commits](#automatic-commits)
8. [Security Considerations](#security-considerations)
9. [Troubleshooting](#troubleshooting)
10. [Uninstallation](#uninstallation)
11. [Contributing](#contributing)
12. [License](#license)

---

## Overview

cont-AI-nerd creates a sandboxed environment where an AI coding agent (OpenCode) can:

- **Read and modify files** in designated project directories
- **Run in isolation** from your host system
- **Persist tool installations** across container restarts
- **Track file changes** with automatic permission management
- **Commit container state** periodically for durability

### Key Features

- **Rootful Podman container** with UID/GID mapping to host users
- **Systemd integration** via Podman Quadlet for service management
- **File watcher service** that maintains correct permissions on new files
- **Periodic container commits** to preserve installed tools and state
- **Interactive TUI** that attaches to the running headless server
- **JSON-based configuration** for easy customization

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              HOST SYSTEM                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────┐     ┌──────────────────┐     ┌─────────────────┐  │
│  │  Primary User    │     │  File Watcher    │     │  Commit Timer   │  │
│  │  (e.g., alice)   │     │  (systemd)       │     │  (systemd)      │  │
│  │                  │     │                  │     │                 │  │
│  │  - Owns files    │     │  - Monitors      │     │  - Runs hourly  │  │
│  │  - Member of ai  │     │    project dirs  │     │  - Commits      │  │
│  │    group         │     │  - Fixes perms   │     │    container    │  │
│  └──────────────────┘     └──────────────────┘     └─────────────────┘  │
│           │                        │                        │           │
│           │                        │                        │           │
│           ▼                        ▼                        ▼           │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │           /home/alice/Projects (example, setgid ai)              │   │
│  │                                                                  │   │
│  │   - Group: ai                                                    │   │
│  │   - Directories: g+rxs (read/traverse), add g+w for write        │   │
│  │   - Files: g+r (read), add g+w for write                         │   │
│  │   - Sensitive files (.env, secrets/): mode 700 (agent blocked)   │   │
│  │   - .git/: read-only for ai group                                │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│                                    │ bind mount                         │
│                                    ▼                                    │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    PODMAN CONTAINER                              │   │
│  │                    (cont-ai-nerd)                                │   │
│  ├──────────────────────────────────────────────────────────────────┤   │
│  │                                                                  │   │
│  │  ┌────────────────────────────────────────────────────────────┐  │   │
│  │  │                    OpenCode Server                         │  │   │
│  │  │                                                            │  │   │
│  │  │  - Runs as 'agent' user (UID mapped to host)               │  │   │
│  │  │  - Listens on 127.0.0.1:3000                               │  │   │
│  │  │  - Headless mode (--hostname, --port)                      │  │   │
│  │  │                                                            │  │   │
│  │  └────────────────────────────────────────────────────────────┘  │   │
│  │                              ▲                                   │   │
│  │                              │                                   │   │
│  │  ┌────────────────────────────────────────────────────────────┐  │   │
│  │  │              opencode-tui (optional attach mechanism)      │  │   │
│  │  │                                                            │  │   │
│  │  │  - Wrapper script at /usr/local/bin/opencode-tui           │  │   │
│  │  │  - Attaches TUI to running server                          │  │   │
│  │  │  - Run via: podman exec -it cont-ai-nerd opencode-tui      │  │   │
│  │  │                                                            │  │   │
│  │  └────────────────────────────────────────────────────────────┘  │   │
│  │                                                                  │   │
│  │  Mounts (paths are examples, configured via config.json):        │   │
│  │    - /home/alice/Projects → /home/alice/Projects (rw)            │   │
│  │    - ~/.config/opencode → /home/agent/.config/opencode (ro)      │   │
│  │    - ~/.local/share/opencode → /home/agent/.local/share (ro)     │   │
│  │    - ~/.config/cont-ai-nerd/config.json → /etc/cont-ai-nerd/ (ro)│   │
│  │                                                                  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**Note:** In the diagram above, `~` refers to the primary user's home directory
(e.g., `/home/alice` for user `alice`).

---

## Prerequisites

Before installing cont-AI-nerd, ensure your system meets the following requirements:

### Required

| Dependency | Version | Purpose |
|------------|---------|---------|
| **Linux** | Any modern distro | Host operating system |
| **systemd** | 250+ | Service management |
| **Podman** | 4.0+ | Container runtime (rootful mode) |
| **jq** | 1.6+ | JSON parsing in scripts |

### Optional (installed automatically if missing)

| Dependency | Purpose |
|------------|---------|
| **inotify-tools** | File watcher service (host-side) |
| **git** | Version control in container |

### OpenCode Requirements

You'll need API credentials for at least one LLM provider.
See the [OpenCode documentation](https://opencode.ai/docs/providers) for supported providers and authentication setup.

### Installing Prerequisites

**Fedora/RHEL/CentOS:**
```bash
sudo dnf install podman jq inotify-tools
```

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install podman jq inotify-tools
```

**Arch Linux:**
```bash
sudo pacman -S podman jq inotify-tools
```

---

## Installation

### Quick Start

```bash
# Clone the repository
git clone https://github.com/j-i-l/cont-AI-nerd.git
cd cont-AI-nerd

# Configure (interactive)
sudo ./scripts/configure.sh

# Run setup
sudo ./scripts/setup.sh

# Start the TUI
podman exec -it cont-ai-nerd opencode-tui
```

### Step 1: Clone the Repository

```bash
git clone https://github.com/j-i-l/cont-AI-nerd.git
cd cont-AI-nerd
```

### Step 2: Configure

Run the interactive configuration script to create your settings file:

```bash
sudo ./scripts/configure.sh
```

You'll be prompted for the following settings:

```
=================================================================
  cont-ai-nerd — Configuration
=================================================================

This script will create the configuration file for cont-ai-nerd.
Press Enter to accept the default value shown in brackets.

Primary user [alice]: 
Home directory for alice [/home/alice]: 
Project directories (comma-separated) [/home/alice/Projects]: 
Container agent username [agent]: 
Shared group name [ai]: 
Server listen address [127.0.0.1]: 
Server listen port [3000]: 
Installation directory [/opt/cont-ai-nerd]: 
```

The configuration is saved to `~/.config/cont-ai-nerd/config.json`.

#### Manual Configuration (Optional)

If you prefer to create the configuration file manually:

```bash
mkdir -p ~/.config/cont-ai-nerd
cat > ~/.config/cont-ai-nerd/config.json << 'EOF'
{
  "primary_user": "your-username",
  "primary_home": "/home/your-username",
  "project_paths": [
    "/home/your-username/Projects",
    "/home/your-username/work"
  ],
  "agent_user": "agent",
  "agent_group": "ai",
  "host": "127.0.0.1",
  "port": 3000,
  "install_dir": "/opt/cont-ai-nerd"
}
EOF
chmod 600 ~/.config/cont-ai-nerd/config.json
```

### Step 3: Setup

Run the setup script to build the container and configure services:

```bash
sudo ./scripts/setup.sh
```

The setup script will:

1. **Provision identity** — Create the `agent` user and `ai` group
2. **Configure permissions** — Set up project directories with setgid
3. **Generate policies** — Create OpenCode permission policies
4. **Create directories** — Ensure OpenCode config/data directories exist
5. **Build container** — Build the cont-ai-nerd container image
6. **Install scripts** — Copy helper scripts to `/opt/cont-ai-nerd`
7. **Install systemd units** — Set up Quadlet and service files
8. **Activate services** — Start the container and auxiliary services

Upon completion, you'll see:

```
=================================================================
  cont-ai-nerd setup complete.

  Container : podman ps | grep cont-ai-nerd
  TUI       : podman exec -it cont-ai-nerd opencode-tui
  Watcher   : systemctl status cont-ai-nerd-watcher
  Commits   : systemctl list-timers cont-ai-nerd-commit
  Logs      : journalctl -u cont-ai-nerd -f
=================================================================
```

### Step 4: Configure OpenCode Credentials

Before using the TUI, you need to configure your LLM provider credentials. Start the TUI and run the `/connect` command:

```bash
podman exec -it cont-ai-nerd opencode-tui
```

Then in the TUI:
```
/connect
```

Follow the prompts to authenticate with your preferred provider.

---

## Usage

### Starting the TUI

To interact with the AI agent, attach the terminal UI to the running server:

```bash
podman exec -it cont-ai-nerd opencode-tui
```

The TUI provides an interactive session picker where you can:
- Create new sessions
- Continue previous sessions
- Switch between projects

#### TUI Options

```bash
# Start with a specific session
podman exec -it cont-ai-nerd opencode-tui --session <session-id>

# Start in a specific directory
podman exec -it cont-ai-nerd opencode-tui --dir /path/to/project
```

### Monitoring

#### Check Container Status

```bash
# View running container
podman ps | grep cont-ai-nerd

# Detailed container info
podman inspect cont-ai-nerd
```

#### Check Service Status

```bash
# Container service (via systemd generator)
systemctl status cont-ai-nerd

# File watcher service
systemctl status cont-ai-nerd-watcher

# Commit timer
systemctl list-timers cont-ai-nerd-commit
```

### Viewing Logs

```bash
# Container logs (follow mode)
journalctl -u cont-ai-nerd -f

# File watcher logs
journalctl -u cont-ai-nerd-watcher -f

# Commit service logs
journalctl -u cont-ai-nerd-commit

# All cont-ai-nerd related logs
journalctl -u 'cont-ai-nerd*' --since "1 hour ago"
```

---

## Configuration Reference

The configuration file is located at `~/.config/cont-ai-nerd/config.json`.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `primary_user` | string | **Yes** | — | The primary user who owns project files |
| `primary_home` | string | **Yes** | — | Home directory of the primary user |
| `project_paths` | array | **Yes** | — | List of directories the agent can access |
| `agent_user` | string | No | `"agent"` | Username for the container agent |
| `agent_group` | string | No | `"ai"` | Shared group for file permissions |
| `host` | string | No | `"127.0.0.1"` | Address the server listens on |
| `port` | number | No | `3000` | Port the server listens on |
| `install_dir` | string | No | `"/opt/cont-ai-nerd"` | Where helper scripts are installed |

### Example Configuration

```json
{
  "primary_user": "alice",
  "primary_home": "/home/alice",
  "project_paths": [
    "/home/alice/Projects",
    "/home/alice/work",
    "/home/alice/oss"
  ],
  "agent_user": "agent",
  "agent_group": "ai",
  "host": "127.0.0.1",
  "port": 3000,
  "install_dir": "/opt/cont-ai-nerd"
}
```

### Regenerating Configuration

To update your configuration:

```bash
# Interactive reconfiguration
sudo ./scripts/configure.sh

# Then re-run setup
sudo ./scripts/setup.sh
# Select "recreate" when prompted, or press Enter to use existing config
```

---

## How It Works

### Container Isolation

cont-AI-nerd uses rootful Podman to create a container that:

- **Maps UIDs 1:1** — The `agent` user inside the container has the same UID as the host `agent` user
- **Uses host networking** — Simplifies access; server binds to localhost only
- **Mounts specific directories** — Only project directories are accessible read-write
- **Mounts config read-only** — OpenCode configuration and credentials are read-only
- **Limits resources** — Container is restricted to 2GB RAM and 100 processes

### File Permissions Model

The permissions model allows fine-grained control over what the agent can access:

```
Primary User (e.g., alice)        Agent User (agent)
     │                                  │
     │   member of                      │   primary group
     ▼                                  ▼
┌─────────────────────────────────────────┐
│              ai group                   │
│                                         │
│  Permission Levels:                     │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  g+r   → agent can READ         │    │
│  │  g+rw  → agent can READ + WRITE │    │
│  │  700   → agent BLOCKED          │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Directory requirements:                │
│    - g+rx  for read/traverse access     │
│    - g+rwx for read/write access        │
│    - s (setgid) for group inheritance   │
│                                         │
└─────────────────────────────────────────┘
```

**Permission categories:**

| Category | Mode | Agent Access | Examples |
|----------|------|--------------|----------|
| **Blocked** | `700` | None | `.env`, `secrets/`, `*.key` |
| **Read-only** | `g+r` (files), `g+rx` (dirs) | Read | `.git/`, config files |
| **Read-write** | `g+rw` (files), `g+rwx` (dirs) | Full | Source code, docs |

**Key aspects:**

1. **Setgid on directories** — New files/directories inherit the `ai` group
2. **Granular access** — Set permissions per-file based on sensitivity
3. **Sensitive files blocked** — `.env`, secrets, keys are mode `700` (owner only)
4. **`.git/` read-only** — Agent can read history but not modify it
5. **File watcher** — Fixes permissions on files created by the agent

### Preparing Project Permissions

Before running the agent on your projects, use `prepare-permissions.sh` to set secure permissions:

```bash
# Preview changes (dry-run)
sudo ./scripts/prepare-permissions.sh --dry-run ~/Projects

# Apply permissions
sudo ./scripts/prepare-permissions.sh ~/Projects

# Or use paths from config.json
sudo ./scripts/prepare-permissions.sh --from-config
```

The script applies the following rules:

| Pattern | Mode | Result |
|---------|------|--------|
| `.env`, `.env.*` | `700` | Blocked |
| `secrets/`, `.secrets/`, `vault/` | `700` | Blocked |
| `*.key`, `*.pem`, `id_rsa`, etc. | `700` | Blocked |
| `.git/` | `g=rX` | Read-only |
| Directories | `g+rxs` | Read + setgid |
| Regular files | `g+rw` | Read-write |
| Files with existing `g < 6` | preserved | Keeps restriction |

**Important:** The script preserves existing restrictive permissions. If a file already has more restrictive group permissions (e.g., `g=r` or no group access), those are kept.

### Systemd Services

cont-AI-nerd installs three systemd components:

| Component | Type | Purpose |
|-----------|------|---------|
| `cont-ai-nerd.service` | Quadlet (generated) | Runs the container |
| `cont-ai-nerd-watcher.service` | Service | Monitors files, fixes permissions |
| `cont-ai-nerd-commit.timer` | Timer | Triggers periodic container commits |

**Quadlet Integration:**

The container is managed via Podman Quadlet, which generates a systemd service from the `.container` file in `/etc/containers/systemd/`. This provides:

- Automatic container start on boot
- Proper dependency ordering
- Integration with systemd tooling

### Automatic Commits

The commit timer runs hourly to persist container state:

```bash
# View timer schedule
systemctl list-timers cont-ai-nerd-commit

# Manual commit
sudo systemctl start cont-ai-nerd-commit
```

This preserves:
- Installed tools in `/opt/tools`
- Package manager caches
- Any container filesystem changes

---

## Security Considerations

### What the Agent CAN Access

- **Project directories** (read-write) — Only paths listed in `project_paths`
- **OpenCode config** (read-only) — Your OpenCode settings and themes
- **OpenCode data** (read-only) — Session data and credentials

### What the Agent CANNOT Access

- **Host system files** — No access outside mounted paths
- **Other users' files** — Only the primary user's directories
- **Network services** — Binds to localhost only (127.0.0.1)
- **System configuration** — No access to `/etc`, `/var`, etc.
- **Privileged operations** — Runs as unprivileged `agent` user

### OpenCode Policy File

An OpenCode policy file is automatically generated at `~/.config/cont-ai-nerd/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "external_directory": {
      "/home/alice/Projects/**": "allow"
    }
  }
}
```

This explicitly allows OpenCode to access only the configured project paths.

### Network Binding

The server binds to `127.0.0.1` by default, meaning:
- Only local connections are accepted
- The server is not accessible from other machines
- No firewall configuration is needed

To expose the server to other machines (not recommended), change `host` to `0.0.0.0` in the config.

### Credential Storage

OpenCode credentials are stored in `~/.local/share/opencode/auth.json` on the host and mounted read-only into the container. The container cannot modify these credentials.

---

## Troubleshooting

### Container Won't Start

**Check the service status:**
```bash
systemctl status cont-ai-nerd
journalctl -u cont-ai-nerd -n 50
```

**Common causes:**
- Port already in use: Change `port` in config and re-run setup
- Image not built: Run `sudo ./scripts/setup.sh` again
- Missing config file: Run `sudo ./scripts/configure.sh`

### Permission Denied on Project Files

**Check file permissions:**
```bash
ls -la ~/Projects/
```

**Use the permission preparation script:**
```bash
# Preview what will change
sudo ./scripts/prepare-permissions.sh --dry-run ~/Projects

# Apply secure permissions
sudo ./scripts/prepare-permissions.sh ~/Projects
```

This script sets appropriate permissions while protecting sensitive files (`.env`, secrets, keys) and keeping `.git/` read-only.

**Check if user is in the ai group:**
```bash
groups
# Should include 'ai'

# If not, add yourself and re-login:
sudo usermod -aG ai $USER
# Then log out and back in
```

### TUI Won't Connect

**Ensure the container is running:**
```bash
podman ps | grep cont-ai-nerd
```

**Check the server is listening:**
```bash
podman exec cont-ai-nerd ss -tlnp | grep 3000
```

**Try restarting the container:**
```bash
sudo systemctl restart cont-ai-nerd
```

### File Watcher Not Working

**Check the service:**
```bash
systemctl status cont-ai-nerd-watcher
journalctl -u cont-ai-nerd-watcher -f
```

**Ensure inotify-tools is installed:**
```bash
which inotifywait
# If not found:
sudo dnf install inotify-tools  # Fedora
sudo apt install inotify-tools  # Ubuntu
```

### OpenCode Credentials Not Working

**Verify credentials are mounted:**
```bash
podman exec cont-ai-nerd ls -la /home/agent/.local/share/opencode/
```

**Re-authenticate:**
```bash
podman exec -it cont-ai-nerd opencode-tui
# Then run: /connect
```

### Container Runs Out of Memory

The container is limited to 2GB RAM. To increase:

1. Edit `systemd/cont-ai-nerd.container.in`
2. Change `--memory 2g` to a higher value
3. Re-run `sudo ./scripts/setup.sh`

---

## Uninstallation

To completely remove cont-AI-nerd:

```bash
# Stop and disable services
sudo systemctl stop cont-ai-nerd-watcher
sudo systemctl stop cont-ai-nerd-commit.timer
sudo systemctl stop cont-ai-nerd
sudo systemctl disable cont-ai-nerd-watcher
sudo systemctl disable cont-ai-nerd-commit.timer

# Remove systemd units
sudo rm /etc/systemd/system/cont-ai-nerd-watcher.service
sudo rm /etc/systemd/system/cont-ai-nerd-commit.service
sudo rm /etc/systemd/system/cont-ai-nerd-commit.timer
sudo rm /etc/containers/systemd/cont-ai-nerd.container
sudo systemctl daemon-reload

# Remove the container and image
sudo podman rm -f cont-ai-nerd
sudo podman rmi localhost/cont-ai-nerd:latest

# Remove helper scripts
sudo rm -rf /opt/cont-ai-nerd

# Remove configuration (optional)
rm -rf ~/.config/cont-ai-nerd

# Remove the agent user and ai group (optional)
sudo userdel agent
sudo groupdel ai
```

**Note:** Removing the `ai` group may affect file permissions in your project directories. You may want to reset group ownership first:

```bash
sudo chgrp -R $(id -gn) ~/Projects
```

---

## Contributing

Contributions are welcome! Please follow these guidelines:

### Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/j-i-l/cont-AI-nerd.git`
3. Create a branch: `git checkout -b feature/your-feature`

### Code Style

- **Shell scripts**: Use `shellcheck` for linting
- **Indentation**: 2 spaces for shell scripts
- **Comments**: Use descriptive comments for complex logic
- **Error handling**: Always use `set -euo pipefail` in scripts

### Commit Messages

Follow conventional commit format:

```
type(scope): description

[optional body]

[optional footer]
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

Examples:
```
feat(container): add support for custom resource limits
fix(watcher): handle spaces in directory names
docs(readme): add troubleshooting section for SELinux
```

### Pull Request Process

1. Ensure your code follows the style guidelines
2. Update documentation if needed
3. Test your changes on a clean system if possible
4. Create a pull request with a clear description
5. Reference any related issues

### Testing

Before submitting:

```bash
# Lint shell scripts
shellcheck scripts/*.sh lib/*.sh container/*.sh

# Test the full setup process
sudo ./scripts/configure.sh
sudo ./scripts/setup.sh
podman exec -it cont-ai-nerd opencode-tui
```

### Reporting Issues

When reporting bugs, please include:

- Operating system and version
- Podman version (`podman --version`)
- Relevant log output (`journalctl -u cont-ai-nerd`)
- Steps to reproduce

---

## License

This project is licensed under the **Creative Commons Attribution-NonCommercial 4.0 International License (CC BY-NC 4.0)**.

**You are free to:**
- Share — copy and redistribute the material
- Adapt — remix, transform, and build upon the material

**Under the following terms:**
- **Attribution** — You must give appropriate credit
- **NonCommercial** — You may not use the material for commercial purposes

For commercial licensing inquiries, please contact the maintainers.

See [LICENSE](LICENSE) for the full license text.

---

## Acknowledgments

- [OpenCode](https://opencode.ai) — The AI coding agent powering cont-AI-nerd
- [Podman](https://podman.io) — Daemonless container engine
- [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) — Systemd integration for Podman
