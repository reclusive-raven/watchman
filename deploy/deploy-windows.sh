#!/usr/bin/env bash
set -euo pipefail

BINARY="target/x86_64-pc-windows-gnu/release/watchman-agent.exe"
INSTALLER="deploy/install-windows.ps1"

if [ -z "${WATCHMAN_WINDOWS_WORKERS:-}" ]; then
    echo "Error: set WATCHMAN_WINDOWS_WORKERS to a space-separated list of SSH hosts." >&2
    echo "Append =<name> to a host to report <name> instead of the Windows computer name." >&2
    echo "Example: WATCHMAN_WINDOWS_WORKERS=\"worker-1.lan=gpu-box-1\" ./deploy/deploy-windows.sh" >&2
    exit 2
fi
read -r -a WORKERS <<< "$WATCHMAN_WINDOWS_WORKERS"

if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found at $BINARY"
    echo "Run 'make build-agent-windows' first."
    exit 1
fi

for entry in "${WORKERS[@]}"; do
    worker="${entry%%=*}"
    name=""
    if [ "$entry" != "$worker" ]; then
        name="${entry#*=}"
    fi
    echo "=== Deploying to $worker ==="

    echo "  Copying binary and installer..."
    scp -q "$BINARY" "${worker}:watchman-agent.exe"
    scp -q "$INSTALLER" "${worker}:install-windows.ps1"

    # The SSH user must be an administrator: the installer writes to
    # Program Files and registers a task that runs as SYSTEM.
    ssh "$worker" "powershell -NoProfile -ExecutionPolicy Bypass -File install-windows.ps1${name:+ -AgentHostname $name}"

    echo ""
done

echo "Deployment complete."
