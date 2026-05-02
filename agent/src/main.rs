mod power;

use axum::{extract::State, http::StatusCode, response::Json, routing::get, Router};
use chrono::Utc;
use mdns_sd::{ServiceDaemon, ServiceInfo};
use nvml_wrapper::Nvml;
use serde::Serialize;
use std::sync::Arc;
use sysinfo::{Components, Disks, Networks, System};
use tokio::sync::RwLock;
use tracing::{info, warn};

use crate::power::RaplSampler;

#[derive(Serialize, Clone)]
struct Metrics {
    hostname: String,
    cpu: CpuMetrics,
    gpu: Option<GpuMetrics>,
    memory: MemoryMetrics,
    disk: DiskMetrics,
    io: IoMetrics,
    temps: TempMetrics,
    power: PowerMetrics,
    hardware: HardwareInfo,
    timestamp: String,
}

#[derive(Serialize, Clone, Default)]
struct IoMetrics {
    disk_read_bps: u64,
    disk_write_bps: u64,
    net_rx_bps: u64,
    net_tx_bps: u64,
}

#[derive(Serialize, Clone, Default)]
struct PowerMetrics {
    cpu_w: Option<f32>,
    gpu_w: Option<f32>,
}

#[derive(Serialize, Clone, Default)]
struct HardwareInfo {
    cpu_model: Option<String>,
    gpu_model: Option<String>,
}

#[derive(Serialize, Clone)]
struct CpuMetrics {
    usage_percent: f32,
    core_count: usize,
    per_core: Vec<f32>,
}

#[derive(Serialize, Clone)]
struct GpuMetrics {
    usage_percent: u32,
    vram_used_mb: u64,
    vram_total_mb: u64,
    temp_c: u32,
    fan_speed_percent: u32,
}

#[derive(Serialize, Clone)]
struct MemoryMetrics {
    used_mb: u64,
    total_mb: u64,
}

#[derive(Serialize, Clone)]
struct DiskMetrics {
    used_gb: u64,
    total_gb: u64,
}

#[derive(Serialize, Clone)]
struct TempMetrics {
    cpu_temp_c: Option<f32>,
}

struct AppState {
    metrics: RwLock<Metrics>,
}

fn get_hostname() -> String {
    hostname::get()
        .map(|h| h.to_string_lossy().to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}

fn collect_cpu_metrics(sys: &System) -> CpuMetrics {
    let per_core: Vec<f32> = sys.cpus().iter().map(|c| c.cpu_usage()).collect();
    let usage_percent = if per_core.is_empty() {
        0.0
    } else {
        per_core.iter().sum::<f32>() / per_core.len() as f32
    };
    CpuMetrics {
        usage_percent,
        core_count: sys.cpus().len(),
        per_core,
    }
}

fn collect_memory_metrics(sys: &System) -> MemoryMetrics {
    MemoryMetrics {
        used_mb: sys.used_memory() / 1_048_576,
        total_mb: sys.total_memory() / 1_048_576,
    }
}

fn collect_disk_metrics(disks: &Disks) -> DiskMetrics {
    let mut total: u64 = 0;
    let mut available: u64 = 0;
    for disk in disks.list() {
        total += disk.total_space();
        available += disk.available_space();
    }
    DiskMetrics {
        used_gb: total.saturating_sub(available) / 1_073_741_824,
        total_gb: total / 1_073_741_824,
    }
}

/// Aggregate disk throughput across all physical disks for this refresh window.
fn aggregate_disk_io(disks: &Disks, dt_secs: f64) -> (u64, u64) {
    if dt_secs <= 0.0 {
        return (0, 0);
    }
    let mut read: u64 = 0;
    let mut written: u64 = 0;
    for disk in disks.list() {
        let u = disk.usage();
        read += u.read_bytes;
        written += u.written_bytes;
    }
    (
        (read as f64 / dt_secs) as u64,
        (written as f64 / dt_secs) as u64,
    )
}

/// Aggregate network throughput across all interfaces for this refresh window.
fn aggregate_net_io(networks: &Networks, dt_secs: f64) -> (u64, u64) {
    if dt_secs <= 0.0 {
        return (0, 0);
    }
    let mut rx: u64 = 0;
    let mut tx: u64 = 0;
    for (_, data) in networks.iter() {
        rx += data.received();
        tx += data.transmitted();
    }
    (
        (rx as f64 / dt_secs) as u64,
        (tx as f64 / dt_secs) as u64,
    )
}

fn collect_temp_metrics(components: &Components) -> TempMetrics {
    let mut cpu_temp: Option<f32> = None;
    for component in components.list() {
        let label = component.label().to_lowercase();
        if label.contains("cpu")
            || label.contains("core")
            || label.contains("package")
            || label.contains("tctl")
            || label.contains("tccd")
            || label.contains("k10temp")
        {
            if let Some(temp) = component.temperature() {
                cpu_temp = Some(cpu_temp.map_or(temp, |t: f32| t.max(temp)));
            }
        }
    }
    TempMetrics {
        cpu_temp_c: cpu_temp,
    }
}

fn collect_gpu_metrics(nvml: &Nvml) -> (Option<GpuMetrics>, Option<f32>, Option<String>) {
    let Ok(device) = nvml.device_by_index(0) else {
        return (None, None, None);
    };
    let name = device.name().ok();
    let Ok(utilization) = device.utilization_rates() else {
        return (None, None, name);
    };
    let Ok(memory_info) = device.memory_info() else {
        return (None, None, name);
    };
    let Ok(temp) =
        device.temperature(nvml_wrapper::enum_wrappers::device::TemperatureSensor::Gpu)
    else {
        return (None, None, name);
    };
    let fan = device.fan_speed(0).unwrap_or(0);
    let power_w = power::nvml_power_watts(&device);

    let gpu = GpuMetrics {
        usage_percent: utilization.gpu,
        vram_used_mb: memory_info.used / 1_048_576,
        vram_total_mb: memory_info.total / 1_048_576,
        temp_c: temp,
        fan_speed_percent: fan,
    };
    (Some(gpu), power_w, name)
}

/// Register a Bonjour/mDNS service `_watchman._tcp.local.` pointing at this
/// host:port. The returned `ServiceDaemon` must outlive the agent — dropping
/// it stops the announcement. Returns `None` on any failure; the agent will
/// still serve HTTP, just without auto-discovery.
fn spawn_mdns_announce(hostname: &str, port: u16) -> Option<ServiceDaemon> {
    let daemon = match ServiceDaemon::new() {
        Ok(d) => d,
        Err(e) => {
            warn!("mDNS daemon unavailable: {}", e);
            return None;
        }
    };

    let instance_name = format!("watchman-{hostname}");
    let host_name = format!("{hostname}.local.");
    let info_res = ServiceInfo::new(
        "_watchman._tcp.local.",
        &instance_name,
        &host_name,
        "",
        port,
        None,
    )
    .map(|info| info.enable_addr_auto());

    let info = match info_res {
        Ok(i) => i,
        Err(e) => {
            warn!("mDNS ServiceInfo failed: {}", e);
            return None;
        }
    };

    if let Err(e) = daemon.register(info) {
        warn!("mDNS register failed: {}", e);
        return None;
    }
    info!("mDNS announce: _watchman._tcp.local. -> {}:{}", host_name, port);
    Some(daemon)
}

fn read_cpu_model() -> Option<String> {
    let raw = std::fs::read_to_string("/proc/cpuinfo").ok()?;
    for line in raw.lines() {
        if let Some(rest) = line.strip_prefix("model name") {
            if let Some(colon) = rest.find(':') {
                return Some(rest[colon + 1..].trim().to_string());
            }
        }
    }
    None
}

async fn metrics_handler(State(state): State<Arc<AppState>>) -> Json<Metrics> {
    let metrics = state.metrics.read().await;
    Json(metrics.clone())
}

async fn health_handler() -> (StatusCode, &'static str) {
    (StatusCode::OK, "ok")
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    let hostname = get_hostname();
    info!("Starting watchman-agent on {}", hostname);

    // Best-effort mDNS announce for `_watchman._tcp.local.` so the macOS app's
    // Bonjour browser can auto-discover this agent. Keep the daemon alive for
    // the lifetime of the process; drop it silently if advertisement fails
    // (e.g. containerised deploys without multicast).
    let _mdns_guard = spawn_mdns_announce(&hostname, 8085);

    let initial_metrics = Metrics {
        hostname: hostname.clone(),
        cpu: CpuMetrics {
            usage_percent: 0.0,
            core_count: 0,
            per_core: vec![],
        },
        gpu: None,
        memory: MemoryMetrics {
            used_mb: 0,
            total_mb: 0,
        },
        disk: DiskMetrics {
            used_gb: 0,
            total_gb: 0,
        },
        io: IoMetrics::default(),
        temps: TempMetrics { cpu_temp_c: None },
        power: PowerMetrics::default(),
        hardware: HardwareInfo::default(),
        timestamp: Utc::now().to_rfc3339(),
    };

    let state = Arc::new(AppState {
        metrics: RwLock::new(initial_metrics),
    });

    // Background refresh task for sysinfo (CPU needs two samples ~500ms apart)
    let bg_state = state.clone();
    let bg_hostname = hostname.clone();
    tokio::spawn(async move {
        let mut sys = System::new_all();
        let mut components = Components::new_with_refreshed_list();
        let mut disks = Disks::new_with_refreshed_list();
        let mut networks = Networks::new_with_refreshed_list();
        let nvml = Nvml::init().ok();
        let mut rapl = RaplSampler::new();
        if !rapl.available() {
            info!("RAPL not available — cpu_w will be null");
        }
        let cpu_model = read_cpu_model();
        let mut disk_space_tick: u32 = 0;
        let mut disk_space = collect_disk_metrics(&disks);
        let mut last_io_instant = std::time::Instant::now();

        loop {
            sys.refresh_all();
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            sys.refresh_all();
            components.refresh(true);

            // Disk + network throughput: refresh deltas over wall-clock window.
            disks.refresh(true);
            networks.refresh(true);
            let now = std::time::Instant::now();
            let dt_secs = now.duration_since(last_io_instant).as_secs_f64();
            last_io_instant = now;
            let (disk_read_bps, disk_write_bps) = aggregate_disk_io(&disks, dt_secs);
            let (net_rx_bps, net_tx_bps) = aggregate_net_io(&networks, dt_secs);

            // Refresh disk space (used/total GB) every ~10s; the Disks struct is
            // already refreshed above, so this just re-aggregates space.
            disk_space_tick += 1;
            if disk_space_tick >= 20 {
                disk_space_tick = 0;
                disk_space = collect_disk_metrics(&disks);
            }

            let cpu_w = rapl.sample();

            let (gpu, gpu_w, gpu_model) = if let Some(ref nvml) = nvml {
                // NVML Device is not Send, so use spawn_blocking
                let nvml_ptr = nvml as *const Nvml as usize;
                tokio::task::spawn_blocking(move || {
                    let nvml = unsafe { &*(nvml_ptr as *const Nvml) };
                    collect_gpu_metrics(nvml)
                })
                .await
                .unwrap_or((None, None, None))
            } else {
                (None, None, None)
            };

            let metrics = Metrics {
                hostname: bg_hostname.clone(),
                cpu: collect_cpu_metrics(&sys),
                gpu,
                memory: collect_memory_metrics(&sys),
                disk: disk_space.clone(),
                io: IoMetrics {
                    disk_read_bps,
                    disk_write_bps,
                    net_rx_bps,
                    net_tx_bps,
                },
                temps: collect_temp_metrics(&components),
                power: PowerMetrics { cpu_w, gpu_w },
                hardware: HardwareInfo {
                    cpu_model: cpu_model.clone(),
                    gpu_model,
                },
                timestamp: Utc::now().to_rfc3339(),
            };

            let mut lock = bg_state.metrics.write().await;
            *lock = metrics;
        }
    });

    let app = Router::new()
        .route("/metrics", get(metrics_handler))
        .route("/health", get(health_handler))
        .with_state(state);

    let addr = "0.0.0.0:8085";
    info!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
