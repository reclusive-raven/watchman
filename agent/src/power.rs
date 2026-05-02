use std::fs;
use std::path::PathBuf;
use std::time::Instant;

use nvml_wrapper::Device;

pub struct RaplSampler {
    packages: Vec<PathBuf>,
    max_range_uj: Vec<u64>,
    last_energy_uj: Vec<u64>,
    last_ts: Option<Instant>,
}

impl RaplSampler {
    pub fn new() -> Self {
        let (packages, max_range_uj) = discover_packages();
        let last_energy_uj = vec![0u64; packages.len()];
        Self {
            packages,
            max_range_uj,
            last_energy_uj,
            last_ts: None,
        }
    }

    pub fn available(&self) -> bool {
        !self.packages.is_empty()
    }

    /// Returns instantaneous CPU package power in watts, summed across all
    /// packages. `None` on the first call (no baseline yet) or if any counter
    /// read fails.
    pub fn sample(&mut self) -> Option<f32> {
        if self.packages.is_empty() {
            return None;
        }

        let now = Instant::now();
        let mut current = Vec::with_capacity(self.packages.len());
        for pkg in &self.packages {
            let raw = fs::read_to_string(pkg.join("energy_uj")).ok()?;
            let v: u64 = raw.trim().parse().ok()?;
            current.push(v);
        }

        let prev_ts = match self.last_ts {
            Some(t) => t,
            None => {
                self.last_energy_uj = current;
                self.last_ts = Some(now);
                return None;
            }
        };

        let dt = now.duration_since(prev_ts).as_secs_f64();
        if dt <= 0.0 {
            return None;
        }

        let mut total_uj: u128 = 0;
        for i in 0..self.packages.len() {
            let cur = current[i];
            let prev = self.last_energy_uj[i];
            let delta = if cur >= prev {
                (cur - prev) as u128
            } else {
                // Counter wrap: wrap occurs at max_range_uj
                let max = self.max_range_uj[i];
                if max == 0 {
                    continue;
                }
                ((max - prev) + cur) as u128
            };
            total_uj += delta;
        }

        self.last_energy_uj = current;
        self.last_ts = Some(now);

        // 1 microjoule / 1 second = 1 microwatt. Convert to watts.
        let watts = (total_uj as f64) / 1_000_000.0 / dt;
        Some(watts as f32)
    }
}

fn discover_packages() -> (Vec<PathBuf>, Vec<u64>) {
    let base = PathBuf::from("/sys/class/powercap");
    let mut packages = Vec::new();
    let mut max_range = Vec::new();

    let Ok(entries) = fs::read_dir(&base) else {
        return (packages, max_range);
    };

    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        // Top-level packages are "intel-rapl:0", "intel-rapl:1" (one per socket).
        // Subzones like "intel-rapl:0:0" are cores/uncore — skip to avoid double counting.
        if !name.starts_with("intel-rapl:") {
            continue;
        }
        if name.matches(':').count() != 1 {
            continue;
        }
        let path = entry.path();
        if !path.join("energy_uj").exists() {
            continue;
        }
        let max = fs::read_to_string(path.join("max_energy_range_uj"))
            .ok()
            .and_then(|s| s.trim().parse::<u64>().ok())
            .unwrap_or(0);
        packages.push(path);
        max_range.push(max);
    }

    (packages, max_range)
}

/// Convert NVML milliwatt power to watts.
pub fn nvml_power_watts(device: &Device) -> Option<f32> {
    device.power_usage().ok().map(|mw| (mw as f32) / 1000.0)
}
