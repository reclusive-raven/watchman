# Watchman

A macOS menu-bar monitor for a fleet of Linux GPU workers. Tiny Rust agent on each box, SwiftUI menu-bar client on the Mac. Shows live CPU, GPU, RAM, disk, temps, power draw, and I/O at a glance, fires native macOS alerts on threshold breaches, and keeps 90 days of history in SQLite for export.

Built for personal homelab and small-lab fleets where running Grafana feels like overkill.

## Architecture

Two parts:

- **Agent** ([`agent/`](agent/)) — Stateless Rust HTTP server. Runs on each Linux GPU worker, exposes JSON metrics on `:8085`, advertises itself over mDNS as `_watchman._tcp.local.`. Reads CPU/RAM/disk/network from `sysinfo`, GPU + GPU power from NVML, and CPU power from RAPL (`/sys/class/powercap/intel-rapl:*/energy_uj`).
- **App** ([`app/`](app/)) — SwiftUI macOS menu-bar app. Polls all enabled agents at 1 Hz over HTTP, renders live status with color-coded indicators, persists samples to SQLite (`~/Library/Application Support/Watchman/power.sqlite`), fires `UNUserNotification`s on edge-detected threshold breaches, and exports CSV on demand. Also runs a Bonjour browser to auto-discover agents on the LAN.

Endpoints on the agent: `GET /metrics` (JSON), `GET /health` (liveness).

## Build & install

### Agent (Linux GPU workers)

Cross-compiled from the Mac via [`cargo-zigbuild`](https://github.com/rust-cross/cargo-zigbuild) so you don't need a Linux toolchain:

```bash
# Prerequisites
cargo install cargo-zigbuild
brew install zig            # macOS host

# Build
make build-agent            # → target/x86_64-unknown-linux-gnu/release/watchman-agent

# Deploy via SSH (set worker hosts in env var)
WATCHMAN_WORKERS="worker-1.lan worker-2.lan" make deploy

# One-time: grant read access to RAPL counters so cpu_w is non-null
WATCHMAN_WORKERS="worker-1.lan worker-2.lan" ./deploy/deploy.sh --install-rapl
```

The deploy script `scp`s the binary and a systemd **user** unit (`deploy/watchman-agent.service`) to each worker, then `systemctl --user enable --now watchman-agent`. To survive logout, run `sudo loginctl enable-linger $USER` once on each worker.

### App (macOS)

Open `app/Watchman.xcodeproj` in Xcode 16+ on macOS 14+ and Build & Run. The app appears in the menu bar (no Dock icon — `LSUIElement: true`). No code signing required; `CODE_SIGN_IDENTITY` is set to `-`.

If you want to regenerate the Xcode project from `app/project.yml`:

```bash
brew install xcodegen
cd app && xcodegen generate
```

## Configure

On first launch the worker list is empty. Two ways to add workers:

1. **Bonjour auto-discovery** — Settings → Workers → click the "+" picker. Any agent advertising `_watchman._tcp.` on the LAN appears here.
2. **Manual** — Settings → Workers → "Add" → enter hostname (e.g. `worker-1.lan`) and port (default 8085).

Other knobs in Settings:

- **Alerts** tab — Enable/disable the five alert rules (unreachable, GPU temp, VRAM, disk, GPU-util crash) and tune their hysteresis thresholds.
- **Thresholds** / **Display** tab — Color thresholds for the menu-bar text and worker cards (red/yellow at 85% / 70% by default for usage; tunable for temps and RAM).
- **Export** tab — CSV export of any time range, raw 1 Hz samples.

Data lives at `~/Library/Application Support/Watchman/power.sqlite` (WAL mode, schema v4, 90-day rolling purge).

## Alert rules

Five edge-triggered rules with hysteresis where it matters:

| Rule | Trigger / Clear | Notes |
|---|---|---|
| Unreachable | N consecutive missed polls | Default N=5 (≈5s at 1 Hz). Restart re-arms but the gate still applies. |
| GPU temp | configurable trigger / clear | Hysteresis prevents flapping. |
| VRAM | configurable trigger / clear | Per-worker, not per-GPU-process. |
| Disk | configurable trigger / clear | Used / total. |
| GPU-util crash | sustained low % after sustained high % over N seconds | Catches stuck training jobs that go quiet. |

Per-worker `LastAlertState` is in-memory only — restart re-arms but the unreachable miss-counter still gates retriggers.

## License

MIT. See [LICENSE](LICENSE).
