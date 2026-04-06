# cont-AI-nerd Architecture

## Overview

cont-AI-nerd runs an AI coding agent (OpenCode) inside a sandboxed Podman
container. The system is designed as a **per-user application** — each user
runs their own container instance with their own configuration.

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
- An `agent` user whose group GID matches the primary user's group on the host
- An entrypoint wrapper (`entrypoint.sh`) that handles path translation
  and privilege dropping
- `opencode-tui.sh` for attaching a TUI to the running server

### Entrypoint (`container/entrypoint.sh`)

The entrypoint runs as root and performs three tasks before starting OpenCode:

1. **Path symlink creation**: Reads `path_map` from `/etc/cont-ai-nerd/config.json`
   and creates symlinks from host-side paths to their `/workspace/` equivalents.
   This allows OpenCode clients to use host-side paths as working directories.

2. **Umask configuration**: Sets `umask 002` so that files created by the agent
   are group-writable (`664` for files, `775` for directories). This ensures
   the primary user can always read and write agent-created files.

3. **Privilege dropping**: Uses `setpriv` to drop to the `agent` user before
   executing `opencode serve`.

### NixOS Module (`nix/module.nix`)

Declarative NixOS configuration that:
- Creates the `agent` system user
- Generates `config.json` (with `path_map`) and `opencode.json` policy
- Builds the container image via `podman build` (passing the primary user's
  GID so the agent shares the same group inside the container)
- Installs the Quadlet `.container` file
- Sets up the file watcher and commit timer services

### Shell Scripts (`scripts/`)

For non-NixOS deployments:
- `configure.sh` -- interactive configuration generator
- `setup.sh` -- provisions users, builds the container, installs systemd units
- `prepare-permissions.sh` -- ensures directory traversal permissions

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

### How the Agent Gets Access

When you configure `projectPaths`, you are **opting in** to the agent being
able to access those directories. This is the primary access control
mechanism.

Inside the container, the `agent` user belongs to a group whose GID matches
your (the primary user's) primary group. This means:

- **Any file you own with group-read permission (`g+r`) is readable by the
  agent** — and on most Linux systems, the default umask (`022`) creates
  files with `644` permissions, so group-read is on by default.

- **The agent can only access files within the directories you've explicitly
  configured** in `projectPaths`. It has no access to the rest of your
  home directory or system.

Think of it this way: by adding a directory to `projectPaths`, you're
saying "the agent can work with files in this folder, just like a
colleague who's in my team." The agent reads what your group can read
and writes what your group can write.

### Controlling Access

| What you want                    | How to do it                                  |
|----------------------------------|-----------------------------------------------|
| Agent can read and write a file  | Default for files with `g+rw` (or `664`)      |
| Agent can read but not write     | `chmod g-w file` (mode `644`)                 |
| Agent completely blocked         | `chmod 600 file` (removes all group access)   |
| Agent blocked from a directory   | `chmod 700 dir` (removes group traversal)     |

### Agent-Created Files

The agent runs with `umask 002`, so files it creates are:
- Files: `664` (owner rw, group rw, other r)
- Directories: `775` (owner rwx, group rwx, other rx)

This ensures you (the primary user) can always read and write files the
agent creates, since you share the same group.

### The File Watcher

The `cont-ai-nerd-watcher` systemd service monitors project directories via
inotify. When the agent creates or modifies files (inside the container via
bind mounts), the watcher reassigns ownership from `agent` to the primary
user and defensively ensures group-write permission (`g+w` on files, `g+ws`
on directories). This makes the system robust regardless of the umask that
was active when the file was created (e.g. the entrypoint sets `umask 002`,
but `podman exec` inherits the default `022`).

### `.git/` Directories

The `prepare-permissions.sh` script sets `.git/` directories to group
read-only (`g-w` on contents). This means the agent can read git state
(branches, commits, etc.) but cannot directly modify git internals. The
agent can still commit via git commands — it just can't tamper with the
`.git/` directory directly.

## Container Lifecycle

### Startup Flow

```
systemd starts cont-ai-nerd.service (via Quadlet)
  -> podman creates container from localhost/cont-ai-nerd:latest
  -> entrypoint.sh runs as root:
       1. Reads /etc/cont-ai-nerd/config.json
       2. Creates symlinks: /home/alice/Projects -> /workspace/Projects
       3. Sets umask 002
       4. Drops to agent user via setpriv
       5. Execs: opencode serve --hostname 127.0.0.1 --port 3000
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
