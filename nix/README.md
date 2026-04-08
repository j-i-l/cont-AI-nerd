# cont[AI]*nerd* - NixOS Installation

This directory contains a NixOS flake module that declaratively manages
the entire cont-ai-nerd deployment: users, systemd services, Podman
Quadlet container, and file permissions.

For the general (non-NixOS) installation, see the main
[README](../README.md).

---

## Prerequisites

- **NixOS** with [flakes enabled](https://wiki.nixos.org/wiki/Flakes)
- **Podman** (enabled automatically by the module)
- API credentials for at least one LLM provider - see the
  [OpenCode docs](https://opencode.ai/docs/providers)

---

## Installation

### 1. Add the flake input

In your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    cont-ai-nerd = {
      url = "github:j-i-l/cont-AI-nerd";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, cont-ai-nerd, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        cont-ai-nerd.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

### 2. Configure the module

In your `configuration.nix` (or a dedicated module file):

```nix
{ config, ... }:
{
  services.cont-ai-nerd = {
    enable = true;

    # Required
    primaryUser  = "alice";
    projectPaths = [ "/home/alice/Projects" ];

    # Optional (shown with defaults)
    # primaryHome = "/home/alice";
    # agent.user  = "agent";
    # server.host = "127.0.0.1";
    # server.port = 3000;
    # container.memoryLimit    = "2g";
    # container.pidsLimit      = 100;
    # container.opencodeVersion = "latest";
  };
}
```

### 3. Apply

```bash
sudo nixos-rebuild switch
```

This will:
1. Create the `agent` system user (sharing the primary user's group)
2. Enable Podman
3. Build the container image (first run only, or when the Containerfile changes)
4. Generate `config.json` and `opencode.json` in `~/.config/cont-ai-nerd/`
5. Install the Quadlet container file
6. Start the watcher service and commit timer
7. Set project directory permissions

**Note:** Project directories are mounted under `/workspace` inside the container.
The common parent directory is stripped (e.g., `/home/alice/Projects` becomes
`/workspace/Projects`). This avoids issues with home directory traversal.

---

## Module Options Reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable the cont-ai-nerd service |
| `primaryUser` | string | - | Login name of the primary (human) user |
| `primaryHome` | path | `/home/${primaryUser}` | Home directory of the primary user |
| `projectPaths` | list of path | - | Directories the agent can access |
| `agent.user` | string | `"agent"` | Container agent username |
| `server.host` | string | `"127.0.0.1"` | Server listen address |
| `server.port` | port | `3000` | Server listen port |
| `container.memoryLimit` | string | `"2g"` | Container memory limit |
| `container.pidsLimit` | int | `100` | Container PID limit |
| `container.opencodeVersion` | string | `"latest"` | OpenCode version to install |

---

## Post-Deployment

### Configure OpenCode credentials

Run the TUI and use `/connect` to authenticate with your LLM provider:

```bash
sudo cont-ai-nerd-tui
# Then run: /connect
```

Credentials are saved automatically and persist across sessions — no restart needed.

### Access the TUI

```bash
sudo cont-ai-nerd-tui
```

This attaches an interactive TUI to the headless OpenCode server running inside the container. You can use `/connect` at any time to authenticate or re-authenticate with an LLM provider.

### Prepare project permissions

For fine-grained permission control (locking `.env`, secrets, making `.git/`
read-only), use the bundled preparation script:

```bash
# Preview changes
sudo cont-ai-nerd-prepare-permissions --dry-run ~/Projects

# Apply
sudo cont-ai-nerd-prepare-permissions ~/Projects

# Or read paths from the generated config
sudo cont-ai-nerd-prepare-permissions --from-config
```

---

## Updating

To update the container image after a new OpenCode release:

```nix
# Pin a specific version
services.cont-ai-nerd.container.opencodeVersion = "0.5.0";
```

Then rebuild:

```bash
sudo nixos-rebuild switch
```

The activation script detects Containerfile changes and rebuilds
automatically. To force a rebuild:

```bash
sudo rm /var/lib/cont-ai-nerd/containerfile.sha256
sudo nixos-rebuild switch
```

---

## Development Shell

For contributing to cont-ai-nerd, a development shell is provided:

```bash
nix develop github:j-i-l/cont-AI-nerd

# Or from a local checkout
nix develop
```

This gives you `bash`, `jq`, `podman`, `inotify-tools`, and `shellcheck`.

---

## How It Differs from the Imperative Setup

| Aspect | Imperative (`setup.sh`) | NixOS module |
|--------|------------------------|--------------|
| User creation | `useradd` | `users.users` |
| Systemd services | Files copied to `/etc/systemd/system/` | `systemd.services.*` |
| Quadlet file | Template rendered by `sed` | `environment.etc` |
| Configuration | Interactive `configure.sh` | Nix module options |
| Script PATH | Ambient `$PATH` | Nix `makeWrapper` |
| Idempotency | Script checks | Nix guarantees |
| Rollback | Manual | `nixos-rebuild switch --rollback` |
| SELinux labels | `:rw,Z` volume flag | `:rw` (NixOS uses AppArmor or none) |

---

## Troubleshooting

### Container service not starting

```bash
systemctl status cont-ai-nerd
journalctl -u cont-ai-nerd -n 50
```

If the Quadlet generator did not pick up the file:

```bash
ls -la /etc/containers/systemd/
systemctl daemon-reload
```

### Image not built

Check if the activation script ran:

```bash
ls -la /var/lib/cont-ai-nerd/containerfile.sha256
podman images | grep cont-ai-nerd
```

Force a rebuild:

```bash
sudo rm /var/lib/cont-ai-nerd/containerfile.sha256
sudo nixos-rebuild switch
```

### Watcher service errors

```bash
journalctl -u cont-ai-nerd-watcher -f
```

Ensure `inotify-tools` is available (it should be, via `environment.systemPackages`).
