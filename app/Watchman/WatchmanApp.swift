import AppKit
import SwiftUI

@main
struct WatchmanApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var poller: MetricsPoller
    @StateObject private var alerts: AlertsEngine

    init() {
        let settings = AppSettings.shared
        let poller = MetricsPoller(settings: settings)
        let alerts = AlertsEngine(settings: settings)
        poller.alertsEngine = alerts
        _poller = StateObject(wrappedValue: poller)
        _alerts = StateObject(wrappedValue: alerts)
        Task { await alerts.requestAuthorizationIfNeeded() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(poller: poller, settings: settings)
                .preferredColorScheme(.dark)
        } label: {
            Image(nsImage: renderMenuBarImage())
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, alerts: alerts, workers: poller.workers)
                .preferredColorScheme(.dark)
        }

        Window("History", id: "history") {
            HistoryWindow(poller: poller)
        }
        .windowResizability(.contentMinSize)
    }

    // MARK: - Render colored menu bar label as NSImage

    private static let menuBarHeight: CGFloat = 22
    private static let sparklineWidth: CGFloat = 34
    private static let sparklineHeight: CGFloat = 12
    private static let sparklineLead: CGFloat = 4

    private func renderMenuBarImage() -> NSImage {
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let separator = NSAttributedString(
            string: "  │  ",
            attributes: [.font: smallFont, .foregroundColor: NSColor(white: 0.75, alpha: 1)]
        )
        let separatorWidth = separator.size().width

        let metric = settings.sparklineMetric
        let sparklineEnabled = metric != .off

        // Build each worker's segment (text + sparkline data) up front so we
        // can measure the total image width before lockFocus.
        struct Segment {
            let text: NSAttributedString
            let samples: [Double]
            let sparklineColor: NSColor
            let hasSparkline: Bool
        }
        let segments: [Segment] = poller.workers.map { worker in
            let text = buildWorkerSegment(for: worker)
            let samples = SparklineHistory.shared.values(workerId: worker.id)
            let showSparkline = sparklineEnabled
                && samples.count >= 2
                && worker.state != .unreachable
            let color = sparklineColor(for: metric, lastValue: samples.last, worker: worker)
            return Segment(text: text, samples: samples, sparklineColor: color, hasSparkline: showSparkline)
        }

        let segmentWidths: [CGFloat] = segments.map { seg in
            let w = seg.text.size().width
            return seg.hasSparkline ? w + Self.sparklineLead + Self.sparklineWidth : w
        }
        let totalWidth = segmentWidths.reduce(0, +)
            + separatorWidth * CGFloat(max(segments.count - 1, 0))

        let image = NSImage(size: NSSize(width: max(ceil(totalWidth), 1), height: Self.menuBarHeight))
        image.lockFocus()

        var x: CGFloat = 0
        for (i, seg) in segments.enumerated() {
            let textSize = seg.text.size()
            seg.text.draw(at: NSPoint(x: x, y: (Self.menuBarHeight - textSize.height) / 2))
            x += textSize.width

            if seg.hasSparkline {
                let rect = NSRect(
                    x: x + Self.sparklineLead,
                    y: (Self.menuBarHeight - Self.sparklineHeight) / 2,
                    width: Self.sparklineWidth,
                    height: Self.sparklineHeight
                )
                drawSparkline(samples: seg.samples, in: rect, color: seg.sparklineColor)
                x += Self.sparklineLead + Self.sparklineWidth
            }

            if i < segments.count - 1 {
                separator.draw(at: NSPoint(x: x, y: (Self.menuBarHeight - separator.size().height) / 2))
                x += separatorWidth
            }
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func buildWorkerSegment(for worker: WorkerEntry) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let alias = settings.alias(for: worker.id)

        if worker.state == .unreachable {
            result.append(NSAttributedString(
                string: "\(alias) — —",
                attributes: [.font: font, .foregroundColor: NSColor(white: 0.60, alpha: 1)]
            ))
            return result
        }

        // Name
        result.append(NSAttributedString(
            string: "\(alias) ",
            attributes: [.font: smallFont, .foregroundColor: NSColor(white: 0.75, alpha: 1)]
        ))

        // Peak usage with gauge icon
        if let peak = worker.peakUsage {
            let usageColor = nsUsageColor(peak)
            if let gaugeImage = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                if let configured = gaugeImage.withSymbolConfiguration(config) {
                    let tinted = configured.tinted(with: usageColor)
                    let attachment = NSTextAttachment()
                    attachment.image = tinted
                    let iconSize = tinted.size
                    attachment.bounds = CGRect(x: 0, y: -1, width: iconSize.width, height: iconSize.height)
                    result.append(NSAttributedString(attachment: attachment))
                }
            }
            result.append(NSAttributedString(
                string: " \(peak)%",
                attributes: [.font: font, .foregroundColor: usageColor]
            ))
        }

        // Temp with SF Symbol thermometer (colored by temp)
        if let temp = worker.maxTemp {
            result.append(NSAttributedString(
                string: "  ",
                attributes: [.font: smallFont]
            ))

            if let thermImage = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                if let configured = thermImage.withSymbolConfiguration(config) {
                    let tinted = configured.tinted(with: nsTempColor(temp))
                    let attachment = NSTextAttachment()
                    attachment.image = tinted
                    let iconSize = tinted.size
                    attachment.bounds = CGRect(x: 0, y: -1, width: iconSize.width, height: iconSize.height)
                    result.append(NSAttributedString(attachment: attachment))
                }
            }

            result.append(NSAttributedString(
                string: " \(temp)°",
                attributes: [.font: font, .foregroundColor: nsTempColor(temp)]
            ))
        }

        return result
    }

    /// Pick a sparkline color based on the currently selected metric's
    /// semantics and its most recent value, so the line goes red when the
    /// underlying value crosses a threshold.
    private func sparklineColor(for metric: SparklineMetric, lastValue: Double?, worker: WorkerEntry) -> NSColor {
        let neonCyan = NSColor(red: 0x00/255.0, green: 0xE5/255.0, blue: 0xFF/255.0, alpha: 1)
        guard let value = lastValue else { return neonCyan }

        switch metric {
        case .off:
            return neonCyan
        case .gpuUsage, .cpuUsage, .ramPct, .vramPct:
            return nsUsageColor(Int(value.rounded()))
        case .gpuTemp, .cpuTemp:
            return nsTempColor(Int(value.rounded()))
        case .diskReadBps, .netRxBps:
            return neonCyan
        }
    }

    /// Draw a polyline over the samples, normalized to the buffer's own
    /// min/max so even small relative movements are visible. The axis is
    /// local (not global) — a 60 → 65 % climb on one worker renders the
    /// same amplitude as a 30 → 35 % climb on another.
    private func drawSparkline(samples: [Double], in rect: NSRect, color: NSColor) {
        guard samples.count >= 2,
              let ctx = NSGraphicsContext.current?.cgContext
        else { return }

        let minV = samples.min() ?? 0
        let maxV = samples.max() ?? 1
        let span = max(maxV - minV, 1e-6)

        // Flat signal: draw a centered horizontal line instead of a
        // divide-by-zero bump.
        let isFlat = (maxV - minV) < 1e-3

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let path = CGMutablePath()
        for (i, v) in samples.enumerated() {
            let x = rect.minX + CGFloat(i) / CGFloat(samples.count - 1) * rect.width
            let normalized = isFlat ? 0.5 : (v - minV) / span
            let y = rect.minY + CGFloat(normalized) * (rect.height - 2) + 1
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func nsUsageColor(_ percent: Int) -> NSColor {
        if Double(percent) >= settings.usageRedPct {
            return NSColor(red: 0xFF/255.0, green: 0x00/255.0, blue: 0x50/255.0, alpha: 1) // #FF0050
        }
        if Double(percent) >= settings.usageYellowPct {
            return NSColor(red: 0xFF/255.0, green: 0xE5/255.0, blue: 0x00/255.0, alpha: 1) // #FFE500
        }
        return NSColor(red: 0x00/255.0, green: 0xFF/255.0, blue: 0x88/255.0, alpha: 1) // #00FF88
    }

    private func nsTempColor(_ temp: Int) -> NSColor {
        if Double(temp) >= settings.tempRedC {
            return NSColor(red: 0xFF/255.0, green: 0x00/255.0, blue: 0x50/255.0, alpha: 1) // #FF0050
        }
        if Double(temp) >= settings.tempOrangeC {
            return NSColor(red: 0xFF/255.0, green: 0x7A/255.0, blue: 0x00/255.0, alpha: 1) // #FF7A00
        }
        if Double(temp) >= settings.tempYellowC {
            return NSColor(red: 0xFF/255.0, green: 0xE5/255.0, blue: 0x00/255.0, alpha: 1) // #FFE500
        }
        return NSColor(red: 0x66/255.0, green: 0x88/255.0, blue: 0x99/255.0, alpha: 1) // #668899 cool gray, visible on menu bar
    }
}

// MARK: - NSImage tinting helper

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
