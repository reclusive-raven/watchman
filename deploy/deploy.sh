#!/usr/bin/env bash
set -euo pipefail

BINARY="target/x86_64-unknown-linux-gnu/release/watchman-agent"
SERVICE="deploy/watchman-agent.service"
RAPL_RULE="deploy/99-rapl.rules"

if [ -z "${WATCHMAN_WORKERS:-}" ]; then
    echo "Error: set WATCHMAN_WORKERS to a space-separated list of SSH hosts." >&2
    echo "Example: WATCHMAN_WORKERS=\"worker-1.lan worker-2.lan\" ./deploy/deploy.sh" >&2
    exit 2
fi
read -r -a WORKERS <<< "$WATCHMAN_WORKERS"

INSTALL_RAPL=0
for arg in "$@"; do
    case "$arg" in
        --install-rapl) INSTALL_RAPL=1 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found at $BINARY"
    echo "Run 'make build-agent' first."
    exit 1
fi

if [ "$INSTALL_RAPL" = "1" ] && [ ! -f "$RAPL_RULE" ]; then
    echo "Error: --install-rapl requested but $RAPL_RULE is missing"
    exit 1
fi

for worker in "${WORKERS[@]}"; do
    echo "=== Deploying to $worker ==="

    if [ "$INSTALL_RAPL" = "1" ]; then
        echo "  Installing RAPL udev rule (will prompt for sudo password on $worker)..."
        scp "$RAPL_RULE" "${worker}:/tmp/99-rapl.rules"
        ssh -t "$worker" "sudo install -m 644 /tmp/99-rapl.rules /etc/udev/rules.d/99-rapl.rules \
            && sudo udevadm control --reload-rules \
            && sudo udevadm trigger --subsystem-match=powercap \
            && rm -f /tmp/99-rapl.rules"
    fi

    echo "  Creating directories..."
    ssh "$worker" "mkdir -p ~/.local/bin ~/.config/systemd/user"

    echo "  Stopping existing service..."
    ssh "$worker" "systemctl --user stop watchman-agent 2>/dev/null || true"

    echo "  Copying binary..."
    scp "$BINARY" "${worker}:~/.local/bin/watchman-agent"
    ssh "$worker" "chmod +x ~/.local/bin/watchman-agent"

    echo "  Copying systemd unit..."
    scp "$SERVICE" "${worker}:~/.config/systemd/user/watchman-agent.service"

    echo "  Enabling and starting service..."
    ssh "$worker" "systemctl --user daemon-reload && systemctl --user enable --now watchman-agent"

    echo "  Waiting for startup..."
    sleep 2

    echo "  Verifying..."
    if ssh "$worker" "curl -sf http://localhost:8085/health" > /dev/null 2>&1; then
        echo "  ✓ $worker is healthy"
    else
        echo "  ⚠ $worker health check failed (may need a moment to start)"
    fi

    echo ""
done

echo "Deployment complete."
echo ""
echo "NOTE: For the agent to run when not logged in, enable lingering on each worker:"
echo "  sudo loginctl enable-linger \$USER"
echo ""
echo "NOTE: For CPU power draw (RAPL) to work, the udev rule must be installed once:"
echo "  ./deploy/deploy.sh --install-rapl"
