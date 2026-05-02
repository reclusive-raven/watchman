import Foundation

/// Hardcoded maximum-power lookup used to scale the wattage bar.
///
/// - CPU values are AMD PPT (package power tracking) or Intel PL2 (max turbo
///   power). These are what RAPL actually sees, not the marketing TDP.
/// - GPU values are NVIDIA TGP or AMD TBP (total board power).
/// - Substring match, so an agent-reported string like
///   `"AMD Ryzen 9 9950X 16-Core Processor"` matches the `"ryzen 9 9950x"`
///   entry. Table is ordered most-specific-first so `"7800X3D"` does not
///   get hijacked by a generic `"Ryzen 7"` fallback.
enum PowerLimits {
    static let defaultCpu: Double = 125
    static let defaultGpu: Double = 250

    static func cpu(for model: String?) -> Double {
        guard let raw = model else { return defaultCpu }
        let m = raw.lowercased()
        for (needle, watts) in cpuTable where m.contains(needle) {
            return watts
        }
        return defaultCpu
    }

    static func gpu(for model: String?) -> Double {
        guard let raw = model else { return defaultGpu }
        let m = raw.lowercased()
        for (needle, watts) in gpuTable where m.contains(needle) {
            return watts
        }
        return defaultGpu
    }

    // MARK: - CPU table (PPT for AMD, PL2 for Intel)

    private static let cpuTable: [(String, Double)] = [
        // AMD Ryzen 9000 — Zen 5 (AM5)
        ("ryzen 9 9950x3d", 230),
        ("ryzen 9 9950x",   230),
        ("ryzen 9 9900x3d", 200),
        ("ryzen 9 9900x",   200),
        ("ryzen 7 9800x3d", 162),
        ("ryzen 7 9700x",   142),
        ("ryzen 5 9600x",   142),

        // AMD Ryzen 7000 — Zen 4 (AM5)
        ("ryzen 9 7950x3d", 230),
        ("ryzen 9 7950x",   230),
        ("ryzen 9 7900x3d", 230),
        ("ryzen 9 7900x",   230),
        ("ryzen 9 7900",     88),   // non-X, 65W TDP → 88W PPT
        ("ryzen 7 7800x3d", 162),
        ("ryzen 7 7700x",   142),
        ("ryzen 7 7700",     88),
        ("ryzen 5 7600x",   142),
        ("ryzen 5 7600",     88),

        // AMD Ryzen 5000 — Zen 3 (AM4)
        ("ryzen 9 5950x",   142),
        ("ryzen 9 5900x",   142),
        ("ryzen 7 5800x3d", 142),
        ("ryzen 7 5800x",   142),
        ("ryzen 7 5700x3d", 142),
        ("ryzen 7 5700x",    88),   // 65W TDP
        ("ryzen 5 5600x3d", 142),
        ("ryzen 5 5600x",   142),
        ("ryzen 5 5600",     88),

        // AMD Ryzen 3000 — Zen 2 (AM4)
        ("ryzen 9 3950x",   142),
        ("ryzen 9 3900x",   142),
        ("ryzen 7 3800x",   142),
        ("ryzen 7 3700x",    88),
        ("ryzen 5 3600x",    88),
        ("ryzen 5 3600",     88),

        // Intel Core 14th gen (Raptor Lake Refresh) K-series: PL2 253W
        ("i9-14900ks", 253),
        ("i9-14900k",  253),
        ("i9-14900",   219),
        ("i7-14700k",  253),
        ("i7-14700",   219),
        ("i5-14600k",  181),
        ("i5-14600",   154),
        ("i5-14500",   154),

        // Intel Core 13th gen (Raptor Lake): PL2 253W (K-series)
        ("i9-13900ks", 253),
        ("i9-13900k",  253),
        ("i9-13900",   219),
        ("i7-13700k",  253),
        ("i7-13700",   219),
        ("i5-13600k",  181),
        ("i5-13600",   154),
        ("i5-13500",   154),

        // Intel Core 12th gen (Alder Lake)
        ("i9-12900ks", 241),
        ("i9-12900k",  241),
        ("i9-12900",   202),
        ("i7-12700k",  190),
        ("i7-12700",   180),
        ("i5-12600k",  150),
        ("i5-12600",   117),

        // Intel Core 11th gen (Rocket Lake)
        ("i9-11900k",  251),
        ("i9-11900",   224),
        ("i7-11700k",  251),
        ("i7-11700",   224),
        ("i5-11600k",  182),
        ("i5-11600",   154),

        // Intel Core 10th gen (Comet Lake)
        ("i9-10900k",  250),
        ("i9-10900",   224),
        ("i7-10700k",  229),
        ("i7-10700",   180),

        // Generic family fallbacks (must be LAST — only hit when a specific
        // model pattern above didn't match).
        ("ryzen threadripper", 350),
        ("ryzen 9",   230),
        ("ryzen 7",   142),
        ("ryzen 5",   142),
        ("ryzen 3",    88),
        ("core i9",   253),
        ("core i7",   190),
        ("core i5",   150),
        ("core i3",    89),
        ("xeon",      205),
        ("epyc",      280),
    ]

    // MARK: - GPU table (TGP for NVIDIA, TBP for AMD)

    private static let gpuTable: [(String, Double)] = [
        // NVIDIA RTX 50 (Blackwell)
        ("rtx 5090",        575),
        ("rtx 5080",        360),
        ("rtx 5070 ti",     300),
        ("rtx 5070",        250),
        ("rtx 5060 ti",     180),
        ("rtx 5060",        150),

        // NVIDIA RTX 40 (Ada Lovelace)
        ("rtx 4090",        450),
        ("rtx 4080 super",  320),
        ("rtx 4080",        320),
        ("rtx 4070 ti super", 285),
        ("rtx 4070 ti",     285),
        ("rtx 4070 super",  220),
        ("rtx 4070",        200),
        ("rtx 4060 ti",     160),
        ("rtx 4060",        115),

        // NVIDIA RTX 30 (Ampere)
        ("rtx 3090 ti",     450),
        ("rtx 3090",        350),
        ("rtx 3080 ti",     350),
        ("rtx 3080",        320),
        ("rtx 3070 ti",     290),
        ("rtx 3070",        220),
        ("rtx 3060 ti",     200),
        ("rtx 3060",        170),
        ("rtx 3050",        130),

        // NVIDIA RTX 20 (Turing)
        ("rtx 2080 ti",     250),
        ("rtx 2080 super",  250),
        ("rtx 2080",        215),
        ("rtx 2070 super",  215),
        ("rtx 2070",        175),
        ("rtx 2060 super",  175),
        ("rtx 2060",        160),

        // NVIDIA Data-center / workstation (rough max-draw values)
        ("h100",  700),
        ("a100",  400),
        ("l40",   300),
        ("l4",     72),
        ("a40",   300),
        ("a6000", 300),
        ("a5000", 230),
        ("a4000", 140),
        ("rtx 6000 ada", 300),
        ("rtx 5000 ada", 250),

        // NVIDIA GTX 16 (Turing, no RT)
        ("gtx 1660 super",  125),
        ("gtx 1660 ti",     120),
        ("gtx 1660",        120),
        ("gtx 1650 super",  100),
        ("gtx 1650",         75),

        // NVIDIA GTX 10 (Pascal)
        ("gtx 1080 ti",     250),
        ("gtx 1080",        180),
        ("gtx 1070 ti",     180),
        ("gtx 1070",        150),
        ("gtx 1060",        120),

        // AMD Radeon RX 7000 (RDNA 3)
        ("rx 7900 xtx",     355),
        ("rx 7900 xt",      315),
        ("rx 7800 xt",      263),
        ("rx 7700 xt",      245),
        ("rx 7600 xt",      190),
        ("rx 7600",         165),

        // AMD Radeon RX 6000 (RDNA 2)
        ("rx 6950 xt",      335),
        ("rx 6900 xt",      300),
        ("rx 6800 xt",      300),
        ("rx 6800",         250),
        ("rx 6750 xt",      250),
        ("rx 6700 xt",      230),
        ("rx 6700",         175),
        ("rx 6650 xt",      180),
        ("rx 6600 xt",      160),
        ("rx 6600",         132),

        // AMD Radeon RX 5000 (RDNA 1)
        ("rx 5700 xt",      225),
        ("rx 5700",         180),
        ("rx 5600 xt",      160),
        ("rx 5500 xt",      130),

        // Intel Arc (Alchemist / Battlemage)
        ("arc b580",        190),
        ("arc a770",        225),
        ("arc a750",        225),
        ("arc a580",        185),
        ("arc a380",         75),
    ]
}
