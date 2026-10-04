# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Is Watchman

A two-part system for monitoring GPU worker machines from a macOS menu bar:
- **Agent** (`agent/`) — Rust HTTP server on each Linux or Windows GPU worker, exposing system metrics (CPU, NVML GPU, RAM, disk, temps, CPU/GPU power, disk+network I/O, booted OS) on port 8085. Stateless; advertises itself over mDNS as `_watchman._tcp.local.`.
- **App** (`app/`) — SwiftUI macOS menu bar app that polls agents every second, renders live status with colored indicators, persists samples to SQLite, fires macOS notifications on threshold breaches, and exports CSV on demand.

## Build & Deploy Commands

### Agent (Rust, cross-compiled for Linux)

```bash
make build-agent   # cargo-zigbuild → x86_64-unknown-linux-gnu
make run-agent     # Run locally (development)
make deploy        # Build + deploy to all workers via SSH

# One-time: grant read access to RAPL counters so cpu_w is non-null.
./deploy/deploy.sh --install-rapl
```

Requires `cargo-zigbuild`. Worker SSH hosts are passed via the `WATCHMAN_WORKERS` env var to `deploy/deploy.sh` (e.g. `WATCHMAN_WORKERS="worker-1.lan worker-2.lan" make deploy`). The agent runs as a systemd **user** service (`~/.config/systemd/user/watchman-agent.service`).

Windows workers: `make build-agent-windows` (target `x86_64-pc-windows-gnu`, needs `rustup target add x86_64-pc-windows-gnu`) and `WATCHMAN_WINDOWS_WORKERS="host=reported-name" make deploy-windows`. `deploy/install-windows.ps1` runs on the worker over SSH (admin account required) and registers a `watchman-agent` scheduled task as SYSTEM: an at-boot trigger plus a clock trigger repeating every minute with `IgnoreNew`, which restarts a crashed agent (a repeat on the boot trigger itself only starts counting at the next boot), and a zero execution time limit to avoid Task Scheduler's 72-hour kill. `--hostname <name>` overrides the reported hostname, since Windows computer names cap at 15 characters. RAPL and CPU temperature are unavailable there, so `cpu_w`/`cpu_temp_c` are `null`.

### App (Swift/SwiftUI)

Open `app/Watchman.xcodeproj` in Xcode and build/run. Standard macOS menu-bar app targeting the local Mac — not deployed remotely.

## Architecture

### Agent (`agent/src/`)

- `main.rs` — Axum server. A background tokio task refreshes `sysinfo` every 500ms (CPU needs two samples for accurate readings). GPU metrics + GPU power go through NVML via `spawn_blocking` (NVML `Device` is not `Send`). Disk totals refresh every 10s; disk/network throughput is computed as Δbytes/Δt across the 500ms tick. State is shared via `Arc<RwLock<Metrics>>`. mDNS registration runs alongside Axum.
- `os.rs` — `OsInfo`, the booted OS (`family` from the compile target, release `name`, `kernel`), read once at startup. On Windows the feature update ("25H2") and NT version come from the registry via `winreg`, since sysinfo only gives the product name and build.
- `power.rs` — `RaplSampler` reads `/sys/class/powercap/intel-rapl:*/energy_uj` (**package zones only** — subzones are skipped to avoid double-counting), computes Δenergy/Δt, and handles counter wrap against `max_energy_range_uj`. Returns `None` until `deploy/99-rapl.rules` has granted group-read access.

**Endpoints:** `GET /metrics` (JSON), `GET /health` (liveness).

### App (`app/Watchman/`)

**Data flow per 1 Hz tick:**
```
MetricsPoller.fetchAll() — concurrent HTTP to all enabled workers
  ├─ decode WorkerMetrics → update WorkerEntry state (ok/warning/critical/unreachable)
  ├─ MetricStore.ingest(sample)       — actor, writes SQLite (WAL)
  ├─ SparklineHistory.append(...)     — in-memory ring buffer for menu bar
  └─ AlertsEngine.evaluate(...)       — edge-triggered, fires UNUserNotification
```

Read paths (history views, CSV export) go through a **separate** `MetricReader` actor holding its own read-only SQLite connection — slow exports never stall the 1 Hz writer.

**Key types and files:**
- `WatchmanApp.swift` — Entry point. Menu-bar `NSAttributedString` rendering with color-coded thresholds; hosts Settings scene and History window scene.
- `Services/MetricsPoller.swift` — 1 Hz `TaskGroup` poll, diff-merges worker list when `AppSettings.workers` changes live.
- `Services/MetricStore.swift` — Writer actor; SQLite at `~/Library/Application Support/Watchman/power.sqlite` (filename retained for backward compat). Owns schema migrations and the 90-day purge task.
- `Services/MetricReader.swift` — Reader actor; `aggregate()`, `gpuAggregate()`, `systemAggregate()`, `diskAggregate()`, `exportRawCsv()`. Idle threshold is hardcoded at 5% CPU/GPU; gaps > 30 s are skipped when integrating energy.
- `Services/AlertsEngine.swift` — Five edge-detected rules (unreachable gated by `consecutiveUnreachable` ≥ `unreachableMissesTrigger`, GPU temp w/ hysteresis, VRAM, disk, GPU-util crash sustained > N s). Per-worker `LastAlertState` is in-memory only — restart re-arms, but the miss-counter gate means a restart still needs N polls of sustained failure before firing.
- `Services/BonjourBrowser.swift` — Discovers `_watchman._tcp.` agents; user accepts into `WorkerConfig`.
- `Services/SparklineHistory.swift` — Per-worker circular buffer sized to the menu-bar sparkline width.
- `Services/MetricsExporter.swift` — Wraps `MetricReader.exportRawCsv` with file picker.
- `Models/WorkerMetrics.swift` — Mirrors agent JSON (CPU/GPU/Mem/Disk/Io/Temp/Power/HardwareInfo/OsInfo). `OsInfo` is optional (older agents omit it) and drives the raised L/W after each alias in the menu bar and the OS tag in the card header, whose tooltip is `OsInfo.detail`. `WorkerEntry` derives state from thresholds.
- `Models/MetricSample.swift` — Row DTO: timestamp, hostname, cpu/gpu W, usage %, temps, VRAM, memory, disk totals, disk+net throughput.
- `Models/AppSettings.swift` — `@MainActor` singleton backed by `UserDefaults`. Owns the mutable worker list (`WorkerConfig`), all alert thresholds, all display-color thresholds, sparkline metric choice, and `costPerKwh`.
- `Models/AlertConfig.swift`, `Models/PowerLimits.swift` — Alert type enum, per-rule state, and threshold bundles.
- `Views/HistoryWindow.swift` + `Views/HistoryTabs/` — Tabbed history (Power / GPU / System / Disk), each driven by a different `MetricReader` aggregate.
- `Views/SettingsView.swift`, `AlertsTab`, `ThresholdsTab`, `DisplayTab`, `WorkerDetailView`, `ExportView` — Settings scene tabs. `WorkerDetailView` handles add/remove/reorder + Bonjour picker.
- `Views/MenuBarView.swift`, `Views/Components/` — Menu-bar popover cells; `PowerRow` scales CPU W / GPU W bars to 125 W / 300 W budgets.

### SQLite Schema

File: `~/Library/Application Support/Watchman/power.sqlite`, **WAL mode**.

Table `metric_samples` (schema v4), composite PK `(hostname, timestamp)`, plus indexes `idx_host_ts (hostname, timestamp)` and `idx_ts (timestamp)`. Fields: `cpu_w`, `gpu_w` (nullable), `cpu_pct`, `gpu_pct`, `gpu_temp_c`, `cpu_temp_c`, `vram_used_mb`, `vram_total_mb`, `mem_used_mb`, `mem_total_mb`, `disk_used_gb`, `disk_total_gb`, `disk_read_bps`, `disk_write_bps`, `net_rx_bps`, `net_tx_bps`.

**Migration:** on startup, if a legacy `power_samples` table survives alongside `metric_samples`, its rows are merged into `metric_samples` (new columns left `NULL`) and the legacy table is dropped (commit `b3d271d`). Do not remove this path without considering installs that span the migration.

### Thresholds

- **Alert thresholds** (hysteresis, per rule): `gpuTempTrigger`/`Clear`, `vramTrigger`/`Clear`, `diskTrigger`/`Clear`, GPU-crash (`gpuCrashHighPct`, `gpuCrashLowPct`, `gpuCrashSustainedSec`), unreachable (`unreachableMissesTrigger` — N consecutive missed polls at the 1 Hz cadence before firing, default 5), plus per-rule enable toggles — all live in `AppSettings`.
- **Display colors** (menu bar + detail view): `usageRedPct` (default 85), `usageYellowPct` (70); `tempRedC` (85), `tempOrangeC` (75), `tempYellowC` (60); `ramWarningPct` (90).
- **Worker-state classification** in `WorkerEntry` uses the display thresholds, not the alert thresholds.

## Gotchas

- `(hostname, timestamp)` is the PK — running two agents with the same hostname silently collides inserts.
- Idle threshold (5 %) and max-gap (30 s) in `MetricReader` are hardcoded, not in settings.
- Sparkline history is in-memory only; full history lives in SQLite.
- Bonjour is best-effort; if mDNS is blocked, the agent still serves HTTP and workers can be added by hand.
- RAPL reads return `None` until `99-rapl.rules` has been installed *and* the service has been restarted so the new group perms take effect.
- On Windows, probe the agent at `127.0.0.1`, not `localhost`: `localhost` resolves to `::1` first, the agent binds IPv4 only, and Windows retries the refused connection for about 2 s before falling back.
- On the Mac side, don't forget to keep the SQLite file path (`power.sqlite`) stable — it's the on-disk identity relied on by existing installs even though the type was renamed `Metric*`.

## Git workflow

Strict for every repo in the `reclusive-raven` org. The canonical text is in the meta-folder's `CLAUDE.md`, one level up in a local checkout.

- **`main` stays linear.** Commit straight to it, or land a branch by rebasing it onto `main` and running `git merge --ff-only`. On GitHub, **Rebase and merge** is the only button.
- **Titles start with a lower-case letter**, imperative, one short line, with no `feat:`-style prefix. A body is optional: a blank line, then a few plain sentences wrapped at 72 columns.
- **Clean up after every merge**: remove the worktree, delete the branch locally and on GitHub, and drop any stash.
- **Never force-push, rewrite or delete `main`.** A GitHub ruleset enforces it here.
