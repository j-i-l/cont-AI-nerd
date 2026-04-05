# cont-AI-nerd Architecture

## Overview

cont-AI-nerd runs an AI coding agent (OpenCode) inside a sandboxed Podman
container. The host user controls what the agent can access via POSIX group
permissions. The system uses systemd Quadlet files for container lifecycle
management.

```
 Host                            Container
 ----                            ---------
 /home/alice/Projects  ------>   /workspace/Projects  (bind mount, rw)
 /home/alice/work      ------>   /workspace/work      (bind mount, rw)

 ~/.config/cont-ai-nerd/ ---->   /etc/cont-ai-nerd/   (bind mount, ro)
 ~/.config/opencode/     ---->   ~/.config/opencode/   (bind mount, ro)
 ~/.local/share/opencode/
   auth.json             ---->   auth.json             (bind mount, ro)
```

## Components

### Container Image (`container/Containerfile`)

Based on Ubuntu 24.04. Contains:
- The `opencode` binary (downloaded at build time)
- An `agent` user and `ai` group with UIDs/GIDs matching the host
- An entrypoint wrapper (`entrypoint.sh`) that handles path translation
  and privilege dropping
- `opencode-tui.sh` for attaching a TUI to the running server

### Entrypoint (`container/entrypoint.sh`)

The entrypoint runs as root and performs two tasks before starting OpenCode:

1. **Path symlink creation**: Reads `path_map` from `/etc/cont-ai-nerd/config.json`
   and creates symlinks from host-side paths to their `/workspace/` equivalents.
   This allows OpenCode clients to use host-side paths as working directories.

2. **Privilege dropping**: Uses `setpriv` to drop to the `agent` user before
   executing `opencode serve`.

### NixOS Module (`nix/module.nix`)

Declarative NixOS configuration that:
- Creates the `agent` user and `ai` group
- Generates `config.json` (with `path_map`) and `opencode.json` policy
- Builds the container image via `podman build`
- Installs the Quadlet `.container` file
- Sets up the file watcher and commit timer services

### Shell Scripts (`scripts/`)

For non-NixOS deployments:
- `configure.sh` — interactive configuration generator
- `setup.sh` — provisions users, builds the container, installs systemd units
- `prepare-permissions.sh` — sets POSIX permissions on project directories

## Path Translation

### The Problem

OpenCode clients (neovim plugin, TUI) connect to the server with the
host-side project path (e.g., `?directory=/home/alice/projects/foo`).
OpenCode uses this as `Instance.directory`, which becomes the default
working directory (`cwd`) for all shell command execution.

Inside the container, project directories are mounted at `/workspace/...`,
not at their host-side paths. When OpenCode tries to `posix_spawn` a shell
with the host-side path as `cwd`, it fails with `ENOENT` because that
directory doesn't exist in the container's filesystem.

### The Solution

The entrypoint wrapper creates symlinks from host-side paths to their
`/workspace/` equivalents at container startup:

```
Container filesystem (after entrypoint):

/home/alice/Projects  ->  /workspace/Projects   (symlink)
/home/alice/work      ->  /workspace/work        (symlink)
/workspace/Projects/  (actual bind mount from host)
/workspace/work/      (actual bind mount from host)
```

This is driven by the `path_map` field in `config.json`:

```json
{
  "path_map": {
    "/home/alice/Projects": "/workspace/Projects",
    "/home/alice/work": "/workspace/work"
  }
}
```

### Path Map Computation

The container-side paths are computed by finding the common parent directory
of all configured project paths and stripping it:

| Host paths                                    | Common parent   | Container paths                   |
|-----------------------------------------------|-----------------|-----------------------------------|
| `/home/alice/Projects`                        | (single path)   | `/workspace/Projects`             |
| `/home/alice/Projects`, `/home/alice/work`    | `/home/alice`   | `/workspace/Projects`, `/workspace/work` |
| `/home/alice/Projects`, `/home/bob/code`      | `/home`         | `/workspace/alice/Projects`, `/workspace/bob/code` |

### Security Properties

The symlink tree created by the entrypoint:
- Intermediate directories (e.g., `/home/alice/`) are owned by `root:root`
  with mode `755`
- They contain **only** the symlinks to `/workspace/` mounts
- The agent can traverse these directories but cannot:
  - Create files in them (not the owner, directory not group-writable)
  - Read any host home directory contents (they don't exist in the container)
  - Access `.ssh/`, `.bashrc`, or any other dotfiles (they don't exist)

## Permission Model

### Opt-in Group Permissions

The agent's access to project files is controlled via POSIX group permissions.
The primary user decides what the agent can access:

| Desired access     | How to set it                            |
|--------------------|------------------------------------------|
| Agent read + write | `chgrp ai file && chmod g+rw file`       |
| Agent read only    | `chgrp ai file && chmod g+r,g-w file`    |
| Agent blocked      | Leave group as non-`ai`, or `chmod g= file` |
| Owner-only secret  | `chmod 600 file` (blocked even if group is `ai`) |

### Key Rules

- **Agent user**: `agent` (system user, no login shell)
- **Shared group**: `ai` (primary user is also a member)
- **File ownership**: All project files are `primaryUser:ai`
- **Directory traversal**: Directories get `g+rxs` (setgid ensures new files
  inherit the `ai` group)
- **`.git/` directories**: Set to read-only for the `ai` group (agent can
  read git state but not modify it directly)

### File Watcher

The `cont-ai-nerd-watcher` systemd service monitors project directories via
inotify. When the agent creates or modifies files (inside the container via
bind mounts), the watcher:

1. Changes ownership from `agent:ai` to `primaryUser:ai`
2. Sets group read+write permissions (`g+rw`)
3. For directories: sets the setgid bit (`g+rxs`)

This ensures the primary user always owns the files while the agent retains
group-based access.

## Container Lifecycle

### Startup Flow

```
systemd starts cont-ai-nerd.service (via Quadlet)
  -> podman creates container from localhost/cont-ai-nerd:latest
  -> entrypoint.sh runs as root:
       1. Reads /etc/cont-ai-nerd/config.json
       2. Creates symlinks: /home/alice/Projects -> /workspace/Projects
       3. Drops to agent user via setpriv
       4. Execs: opencode serve --hostname 127.0.0.1 --port 3000
```

### Health Check

The container includes a health check that curls
`http://127.0.0.1:${PORT}/global/health` every 30 seconds.

### Commit Timer

The `cont-ai-nerd-commit` timer runs daily to commit the container's
overlay filesystem, preserving any tools the agent installed in
`/opt/tools/bin/`.

## Configuration Files

### `config.json`

Generated by `configure.sh` (non-NixOS) or `module.nix` (NixOS).
Located at `~/.config/cont-ai-nerd/config.json`.

```json
{
  "primary_user": "alice",
  "primary_home": "/home/alice",
  "project_paths": ["/home/alice/Projects", "/home/alice/work"],
  "path_map": {
    "/home/alice/Projects": "/workspace/Projects",
    "/home/alice/work": "/workspace/work"
  },
  "agent_user": "agent",
  "agent_group": "ai",
  "host": "127.0.0.1",
  "port": 3000,
  "install_dir": "/opt/cont-ai-nerd"
}
```

### `opencode.json`

OpenCode policy file. Controls which directories OpenCode is allowed to
access (using container-side `/workspace/` paths):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "external_directory": {
      "/workspace/Projects/**": "allow",
      "/workspace/work/**": "allow"
    }
  }
}
```

## Deployment Options

### NixOS (Recommended)

Add to your NixOS configuration:

```nix
{
  services.cont-ai-nerd = {
    enable = true;
    primaryUser = "alice";
    projectPaths = [ "/home/alice/Projects" "/home/alice/work" ];
  };
}
```

### Non-NixOS (Ubuntu/Debian)

```bash
sudo ./scripts/configure.sh   # Interactive configuration
sudo ./scripts/setup.sh        # Provisions everything
```
