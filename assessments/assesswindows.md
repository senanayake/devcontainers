# Podman Dev Containers Setup for Windows

Diagnostic and setup tools for running VS Code Dev Containers with Podman on Windows, supporting both open internet and corporate (Artifactory) environments.

## Quick Start

### 1. Run Diagnostics

Open PowerShell and run:

```powershell
cd C:\Users\chris\CascadeProjects\podman-devcontainer-setup
.\diagnose-podman.ps1
```

For corporate environments with Artifactory:

```powershell
.\diagnose-podman.ps1 -ArtifactoryUrl "https://artifactory.yourcompany.com"
```

### 2. Follow Recommendations

The script will output:
- Current state of your Podman installation
- Issues found
- Step-by-step recommendations
- Recommended VS Code settings

## Architecture Options

### Option A: Podman Desktop Machine (Recommended)

```
┌─────────────────────────────────────────────────────────┐
│ Windows Host                                            │
│  ┌─────────────┐     ┌────────────────────────────────┐│
│  │ VS Code     │────▶│ Named Pipe                     ││
│  │             │     │ \\.\pipe\podman-machine-default││
│  └─────────────┘     └───────────────┬────────────────┘│
│                                      │                  │
│  ┌───────────────────────────────────▼────────────────┐│
│  │ WSL: podman-machine-default                        ││
│  │  ┌─────────────────────────────────────────────┐   ││
│  │  │ Podman Engine                               │   ││
│  │  │ - Image Store                               │   ││
│  │  │ - Container Runtime                         │   ││
│  │  └─────────────────────────────────────────────┘   ││
│  └────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────┘
```

**Pros:** Simple setup, managed by Podman Desktop
**Cons:** Less control over WSL environment

### Option B: Native Podman in WSL

```
┌─────────────────────────────────────────────────────────┐
│ Windows Host                                            │
│  ┌─────────────┐                                        │
│  │ VS Code     │──────────────────────────┐             │
│  └─────────────┘                          │             │
│                                           │             │
│  ┌────────────────────────────────────────▼───────────┐│
│  │ WSL: Ubuntu                                        ││
│  │  ┌─────────────────────────────────────────────┐   ││
│  │  │ Podman (native install)                     │   ││
│  │  │ Socket: /run/user/1000/podman/podman.sock   │   ││
│  │  └─────────────────────────────────────────────┘   ││
│  └────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────┘
```

**Pros:** Full control, can customize WSL environment
**Cons:** More manual setup required

## Common Fixes

### Enable cgroups v2

Create/edit `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
kernelCommandLine = cgroup_no_v1=all
```

Then restart WSL:
```powershell
wsl --shutdown
```

### Enable systemd in WSL

Edit `/etc/wsl.conf` in your WSL distro:

```ini
[boot]
systemd=true
```

Then restart WSL:
```powershell
wsl --shutdown
```

### Start Podman Socket (WSL Native)

Run **without sudo**:

```bash
systemctl --user enable --now podman.socket
```

Verify:
```bash
ls -l /run/user/$(id -u)/podman/podman.sock
```

### Fix Rootless Permission Issues

Add to your `devcontainer.json`:

```json
{
  "runArgs": ["--userns=keep-id"]
}
```

## Corporate Environment Setup

### Registry Mirrors (Artifactory)

SSH into Podman machine or WSL distro and edit `/etc/containers/registries.conf`:

```toml
unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"

[[registry.mirror]]
location = "artifactory.yourcompany.com/docker-remote"
```

### Registry Authentication

```bash
podman login artifactory.yourcompany.com
```

Credentials stored in `~/.config/containers/auth.json` (on Windows host for Podman Desktop).

### Proxy Configuration

Set environment variables in WSL:

```bash
export HTTP_PROXY=http://proxy.yourcompany.com:8080
export HTTPS_PROXY=http://proxy.yourcompany.com:8080
export NO_PROXY=localhost,127.0.0.1,.yourcompany.com
```

Or configure in Podman Desktop settings.

## VS Code Settings

### For Podman Desktop Machine

```json
{
  "dev.containers.dockerPath": "podman",
  "dev.containers.dockerSocketPath": "npipe:////./pipe/podman-machine-default"
}
```

### For Native WSL Podman

```json
{
  "dev.containers.dockerPath": "/usr/bin/podman",
  "docker.host": "unix:///run/user/1000/podman/podman.sock"
}
```

Replace `1000` with your user ID (`id -u` in WSL).

## Files in This Project

- `diagnose-podman.ps1` - Diagnostic script to check your setup
- `README.md` - This documentation

## Troubleshooting

### "Image not found" after building

**Cause:** Built in one Podman store, VS Code connected to another.

**Fix:** Ensure VS Code socket path matches where you built:
- Podman Desktop: `npipe:////./pipe/podman-machine-default`
- WSL Native: `unix:///run/user/<uid>/podman/podman.sock`

### "Cannot connect to Podman"

1. Check if Podman machine is running: `podman machine list`
2. Start if needed: `podman machine start`
3. Verify connectivity: `podman info`

### "stats not supported in rootless mode"

Enable cgroups v2 - see "Enable cgroups v2" section above.

### Socket permission denied

Make sure you started the socket **without sudo**:
```bash
systemctl --user enable --now podman.socket
```
