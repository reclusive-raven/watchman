import SwiftUI

// MARK: - PillButtonStyle

/// Small rounded-rectangle button with a subtle fill that brightens on
/// hover and dims on press. Signals "clickable" without shouting.
private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration)
    }
}

private struct PillLabel: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    private var bgColor: Color {
        if configuration.isPressed { return Color.white.opacity(0.16) }
        if hovering { return Color.white.opacity(0.10) }
        return Color.white.opacity(0.05)
    }

    private var strokeColor: Color {
        hovering ? Color.white.opacity(0.22) : Color.white.opacity(0.08)
    }

    private var fgColor: Color {
        hovering ? Theme.textPrimary : Theme.textSecondary
    }

    var body: some View {
        configuration.label
            .font(.caption)
            .foregroundStyle(fgColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(bgColor))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(strokeColor, lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}

// MARK: - MenuBarView

struct MenuBarView: View {
    @ObservedObject var poller: MetricsPoller
    @ObservedObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    private var relativeTimestamp: String {
        guard let t = poller.lastPollTime else { return "Not yet polled" }
        let elapsed = Int(-t.timeIntervalSinceNow)
        if elapsed < 2 { return "Updated just now" }
        return "Updated \(elapsed) seconds ago"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("Watchman")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    openWindow(id: "history")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("History", systemImage: "chart.line.uptrend.xyaxis")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle())

                SettingsLink {
                    Image(systemName: "gear")
                }
                .buttonStyle(PillButtonStyle())

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Worker cards
            VStack(spacing: 8) {
                ForEach(poller.workers) { worker in
                    WorkerDetailView(
                        worker: worker,
                        alias: settings.alias(for: worker.id)
                    )
                }
            }
            .padding(.horizontal, 12)

            Spacer().frame(height: 10)

            // Footer — timestamp only
            HStack {
                Text(relativeTimestamp)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 360)
        .background(Theme.panelBg)
    }
}
