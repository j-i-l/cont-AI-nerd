<div align="center">
  <a name="contain"></a>

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/logo-light.svg">
    <img src="docs/logo-light.svg" alt="cont[AI]n logo" width="400">
  </picture>

<p>The Coding Agent Sandbox
  <br>
  providing system isolation and automated change tracking
  <br>
  for <a href="https://opencode.ai">OpenCode</a> and (soon) others.
</p>
</div>
<div align="center">
<br><br>
<pre><small>A project backed by</small>
<br>

<a href="https://github.com/t4d-gmbh"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/t4d-gmbh/.github/main/static/logo/wb/T4D_design_develop.svg"><source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/t4d-gmbh/.github/main/static/logo/bw/T4D_design_develop.svg"><img alt="T4D Logo" src="https://raw.githubusercontent.com/t4d-gmbh/.github/main/static/bw/T4D_design_develop.svg" width="220" style="vertical-align: middle;"></picture></a>
</pre>
</div>


cont[AI]n provides a secure, containerized environment for running an AI coding assistant that can read and write files in your project directories while maintaining strict isolation from the rest of your system.

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

cont[AI]n creates a sandboxed environment where an AI coding agent (OpenCode) can:

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
│  │  - Owns files    │     │  - Monitors      │     │  - Runs daily   │  │
│  │  - Agent shares  │     │    project dirs  │     │  - Commits      │  │
│  │    user's group  │     │  - Fixes perms   │     │    container    │  │
│  └──────────────────┘     └──────────────────┘     └─────────────────┘  │
│           │                        │                        │           │
│           │                        │                        │           │
│           ▼                        ▼                        ▼           │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │           /home/alice/Projects (example)                         │   │
│  │                                                                  │   │
│  │   - Group: primary user's group (agent shares it)                │   │
│  │   - Directories: g+x (traverse)                                  │   │
│  │   - Files: g+r (read), add g+w for write                         │   │
│  │   - Sensitive files (.env, secrets/): mode 700 (agent blocked)   │   │
│  │   - .git/: read-only for group                                   │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│                                    │ bind mount                         │
│                                    ▼                                    │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    PODMAN CONTAINER                              │   │
│  │                    (contain)                                     │   │
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
│  │                                                                  │   │
│  │  Pre-defined Mounts                                              │   │
│  │    - ~/.config/opencode → /home/agent/.config/opencode (ro)      │   │
│  │    - ~/.local/share/opencode → /home/agent/.local/share/... (rw) │   │
│  │    - ~/.local/state/opencode → /home/agent/.local/state/... (rw) │   │
│  │    - ~/.config/contain/config.json → /etc/contain/ (ro)          │   │
│  │                                                                  │   │
│  │  Mounts (paths are examples, configured via config.json):        │   │
│  │    - /home/alice/Projects → /workspace/Projects (rw)             │   │
│  │                                                                  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**Note:** In the diagram above, `~` refers to the primary user's home directory
(e.g., `/home/alice` for user `alice`). Project directories are mounted under
`/workspace` inside the container, with the common parent directory stripped
(e.g., `/home/alice/Projects` becomes `/workspace/Projects`).

---

## Prerequisites

Before installing cont[AI]n, ensure your system meets the following requirements:

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

**NixOS:**

See [nix/README.md](nix/README.md) for the declarative NixOS flake module.

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

# Start the TUI (with auth capability)
sudo contain-tui
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
  contain — Configuration
=================================================================

This script will create the configuration file for contain.
Press Enter to accept the default value shown in brackets.

Primary user [alice]: 
Home directory for alice [/home/alice]: 
Project directories (comma-separated) [/home/alice/Projects]: 
Container agent username [agent]: 
Server listen address [127.0.0.1]: 
Server listen port [3000]: 
Installation directory [/opt/contain]: 
```

The configuration is saved to `~/.config/contain/config.json`.

#### Manual Configuration (Optional)

If you prefer to create the configuration file manually:

```bash
mkdir -p ~/.config/contain
cat > ~/.config/contain/config.json << 'EOF'
{
  "primary_user": "your-username",
  "primary_home": "/home/your-username",
  "project_paths": [
    "/home/your-username/Projects",
    "/home/your-username/work"
  ],
  "agent_user": "agent",
  "host": "127.0.0.1",
  "port": 3000,
  "install_dir": "/opt/contain"
}
EOF
chmod 640 ~/.config/contain/config.json
```

### Step 3: Setup

Run the setup script to build the container and configure services:

```bash
sudo ./scripts/setup.sh
```

The setup script will:

1. **Provision identity** — Create the `agent` user (sharing the primary user's group)
2. **Configure permissions** — Set up project directory traversal
3. **Generate policies** — Create OpenCode permission policies
4. **Create directories** — Ensure OpenCode config/data directories exist
5. **Build container** — Build the contain container image
6. **Install scripts** — Copy helper scripts to `/opt/contain`
7. **Install systemd units** — Set up Quadlet and service files
8. **Activate services** — Start the container and auxiliary services

Upon completion, you'll see:

```
=================================================================
  contain setup complete.

   Container : podman ps | grep contain
   TUI       : sudo contain-tui
   Watcher   : systemctl status contain-watcher
   Commits   : systemctl list-timers contain-commit
   Logs      : journalctl -u contain -f
=================================================================
```

---

## Usage

### Starting the TUI

```bash
sudo contain-tui
```

This attaches an interactive TUI to the headless OpenCode server running inside the container. You can use `/connect` to authenticate with your LLM provider — credentials are saved automatically and persist across sessions (no restart needed).

### Initial Setup: Authenticate with a Provider

On first use, run `/connect` in the TUI to authenticate with your preferred LLM provider (e.g., GitHub Copilot). The server writes credentials to `~/.local/share/opencode/auth.json` and reloads providers automatically.

### TUI Options

```bash
# Start with a specific session
sudo contain-tui --session <session-id>

# Start in a specific directory (container path)
sudo contain-tui --dir /workspace/Projects/myproject
```

### Monitoring

#### Check Container Status

```bash
# View running container
podman ps | grep contain

# Detailed container info
podman inspect contain
```

#### Check Service Status

```bash
# Container service (via systemd generator)
systemctl status contain

# File watcher service
systemctl status contain-watcher

# Commit timer
systemctl list-timers contain-commit
```

### Viewing Logs

```bash
# Container logs (follow mode)
journalctl -u contain -f

# File watcher logs
journalctl -u contain-watcher -f

# Commit service logs
journalctl -u contain-commit

# All contain related logs
journalctl -u 'contain*' --since "1 hour ago"
```

---

## Configuration Reference

The configuration file is located at `~/.config/contain/config.json`.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `primary_user` | string | **Yes** | — | The primary user who owns project files |
| `primary_home` | string | **Yes** | — | Home directory of the primary user |
| `project_paths` | array | **Yes** | — | List of directories the agent can access |
| `agent_user` | string | No | `"agent"` | Username for the container agent |
| `host` | string | No | `"127.0.0.1"` | Address the server listens on |
| `port` | number | No | `3000` | Port the server listens on |
| `install_dir` | string | No | `"/opt/contain"` | Where helper scripts are installed |

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
  "host": "127.0.0.1",
  "port": 3000,
  "install_dir": "/opt/contain"
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

cont[AI]n uses rootful Podman to create a container that:

- **Maps UIDs 1:1** — The `agent` user inside the container has the same UID as the host `agent` user
- **Uses host networking** — Simplifies access; server binds to localhost only
- **Mounts specific directories** — Only project directories are accessible read-write
- **Mounts config read-only** — OpenCode configuration is read-only
- **Mounts data read-write** — OpenCode data (database, credentials, model state) is read-write
- **Limits resources** — Container is restricted to 2GB RAM and 100 processes

### File Permissions Model

The permissions model uses standard Unix group permissions. The agent inside the container shares the primary user's group GID directly — no dedicated group is needed. **You opt in** by adding directories to `projectPaths` in the configuration:

```
Primary User (e.g., alice)        Agent User (agent)
     │                                  │
     │   primary group                  │   mapped to same GID
     ▼                                  ▼
┌─────────────────────────────────────────┐
│        Primary user's group             │
│                                         │
│  Permission Levels (you choose):        │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  g+rw  → agent can READ + WRITE │    │
│  │  g+r   → agent can READ only    │    │
│  │  g=    → agent BLOCKED          │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Directory requirements:                │
│    - g+x   for traverse access          │
│    - g+rx  for read/traverse access     │
│    - g+rwx for read/write access        │
│                                         │
└─────────────────────────────────────────┘
```

**Setting agent access:**

| Goal | Command |
|------|---------|
| **Read + Write** | `chmod g+rw file` |
| **Read only** | `chmod g+r,g-w file` |
| **Blocked** | `chmod 600 file` |

For directories, add the execute bit:

```bash
# Make directory traversable
chmod g+x ~/Projects/myproject

# Recursively grant read+write access
chmod -R g+rw ~/Projects/myproject
find ~/Projects/myproject -type d -exec chmod g+x {} \;
```

**Key aspects:**

1. **Opt-in model** — By adding a directory to `projectPaths`, you opt in to the agent accessing files in that directory
2. **Standard group permissions** — The agent shares the primary user's group; no special group is created
3. **Granular access** — Set permissions per-file based on sensitivity
4. **`.git/` read-only** — The prepare script sets `.git/` to read-only automatically
5. **File watcher** — Fixes ownership on files created by the agent

### Preparing Project Permissions

The `prepare-permissions.sh` script makes project directories **traversable** for the agent. It does not change individual file permissions — you control what the agent can read/write.

```bash
# Preview changes (dry-run)
sudo ./scripts/prepare-permissions.sh --dry-run ~/Projects

# Make directories traversable
sudo ./scripts/prepare-permissions.sh ~/Projects

# Use paths from config.json
sudo ./scripts/prepare-permissions.sh --from-config
```

**What the script does:**

| Target | Action | Result |
|--------|--------|--------|
| `.git/` directories | `chmod -R g=rX,g-w` | Agent can read history, cannot modify |
| Other directories | `chmod g+x` | Agent can traverse |
| Sensitive files | *unchanged by default* | Your existing permissions preserved |
| Regular files | *unchanged* | Set permissions yourself |

**Handling sensitive files:**

The script detects sensitive files (`.env`, `secrets/`, `*.key`, etc.) but does **not** lock them by default. You have three options:

```bash
# Option 1: Lock all sensitive files automatically
sudo ./scripts/prepare-permissions.sh --lock-sensitive ~/Projects

# Option 2: Interactive prompt (default when running in terminal)
sudo ./scripts/prepare-permissions.sh ~/Projects
# → Script will ask: "Lock these from the agent? [1] Yes [2] No"

# Option 3: Skip sensitive file handling entirely
sudo ./scripts/prepare-permissions.sh --no-lock-sensitive ~/Projects
```

When locked, sensitive files get mode `600` (files) or `700` (directories), making them inaccessible to the agent.

**Sensitive patterns detected:**

- Environment: `.env`, `.env.*`, `*.env`
- Secrets: `secrets/`, `.secrets/`, `vault/`, `credentials/`
- Keys: `*.pem`, `*.key`, `id_rsa`, `id_ed25519`, etc.
- Auth: `.npmrc`, `.pypirc`, `.netrc`, `*auth*.json`
- Databases: `*.sqlite`, `*.db`

### Systemd Services

cont[AI]n installs three systemd components:

| Component | Type | Purpose |
|-----------|------|---------|
| `contain.service` | Quadlet (generated) | Runs the container |
| `contain-watcher.service` | Service | Monitors files, fixes permissions |
| `contain-commit.timer` | Timer | Triggers periodic container commits |

**Quadlet Integration:**

The container is managed via Podman Quadlet, which generates a systemd service from the `.container` file in `/etc/containers/systemd/`. This provides:

- Automatic container start on boot
- Proper dependency ordering
- Integration with systemd tooling

### Automatic Commits

The commit timer runs hourly to persist container state:

```bash
# View timer schedule
systemctl list-timers contain-commit

# Manual commit
sudo systemctl start contain-commit
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
- **OpenCode data** (read-write) — Session data, credentials, and model preferences

### What the Agent CANNOT Access

- **Host system files** — No access outside mounted paths
- **Other users' files** — Only the primary user's directories
- **Network services** — Binds to localhost only (127.0.0.1)
- **System configuration** — No access to `/etc`, `/var`, etc.
- **Privileged operations** — Runs as unprivileged `agent` user

### OpenCode Policy File

An OpenCode policy file is automatically generated at `~/.config/contain/opencode.json`:

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

OpenCode credentials are stored in `~/.local/share/opencode/auth.json` on the host. The `~/.local/share/opencode/` and `~/.local/state/opencode/` directories are mounted read-write into the container, so `/connect` can save credentials directly. After authentication, the server reloads providers automatically — no container restart is needed.

---

## Troubleshooting

### Container Won't Start

**Check the service status:**
```bash
systemctl status contain
journalctl -u contain -n 50
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

### TUI Won't Connect

**Ensure the container is running:**
```bash
podman ps | grep contain
```

**Check the server is listening:**
```bash
podman exec contain ss -tlnp | grep 3000
```

**Try restarting the container:**
```bash
sudo systemctl restart contain
```

### File Watcher Not Working

**Check the service:**
```bash
systemctl status contain-watcher
journalctl -u contain-watcher -f
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
sudo podman exec contain ls -la /home/agent/.local/share/opencode/
```

**Re-authenticate using the TUI:**
```bash
sudo contain-tui
# Then run: /connect
```

### Container Runs Out of Memory

The container is limited to 2GB RAM. To increase:

1. Edit `systemd/contain.container.in`
2. Change `--memory 2g` to a higher value
3. Re-run `sudo ./scripts/setup.sh`

---

## Uninstallation

To completely remove cont[AI]n:

```bash
# Stop and disable services
sudo systemctl stop contain-watcher
sudo systemctl stop contain-commit.timer
sudo systemctl stop contain
sudo systemctl disable contain-watcher
sudo systemctl disable contain-commit.timer

# Remove systemd units
sudo rm /etc/systemd/system/contain-watcher.service
sudo rm /etc/systemd/system/contain-commit.service
sudo rm /etc/systemd/system/contain-commit.timer
sudo rm /etc/containers/systemd/contain.container
sudo systemctl daemon-reload

# Remove the container and image
sudo podman rm -f contain
sudo podman rmi localhost/contain:latest

# Remove helper scripts
sudo rm -rf /opt/contain

# Remove configuration (optional)
rm -rf ~/.config/contain

# Remove the agent user (optional)
sudo userdel agent
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
podman exec -it contain opencode-tui
```

### Reporting Issues

When reporting bugs, please include:

- Operating system and version
- Podman version (`podman --version`)
- Relevant log output (`journalctl -u contain`)
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

- [OpenCode](https://opencode.ai) — The AI coding agent powering cont[AI]n
- [Podman](https://podman.io) — Daemonless container engine
- [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) — Systemd integration for Podman
