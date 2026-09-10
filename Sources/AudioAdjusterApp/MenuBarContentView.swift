import AppKit
import AudioAdjusterKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if model.processes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.processes) { process in
                            AppRow(model: model, process: process)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 340)
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Volume").font(.headline)
            if model.isBalanceEnabled, model.processes.count > 1 {
                Text(String(format: "total %.0f%%", model.balanceTotal * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasAdjustments {
                Button("Reset") { model.resetAll() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var antiDuckStatus: String {
        guard model.isAntiDuckEnabled else { return "Restore audio muted by the call" }
        guard model.isDuckCalibrated else { return "Measuring the call's ducking…" }
        return String(format: "Compensating %.0f×", model.duckCompensation)
    }

    private var emptyState: some View {
        Text("No apps are playing audio.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.isBalanceEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Balance")
                    Text("Turning one app up turns the others down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            // Only shown during a call. Outside one there is no duck to cancel, and a
            // switch that cannot do anything is worse than no switch.
            if model.isCallActive {
                Toggle(isOn: $model.isAntiDuckEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Anti-duck")
                        Text(antiDuckStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct AppRow: View {
    @ObservedObject var model: AppModel
    let process: AudioProcess

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                icon
                Text(process.name).lineLimit(1)
                if process.isPlaying {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .help("Playing audio")
                }
                Spacer()
                Text(percentLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if model.isProtected(process.bundleID) {
                Text("Call audio — adjusting this makes calls quieter")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    model.toggleMute(process.bundleID)
                } label: {
                    Image(systemName: model.isMuted(process.bundleID) ? "speaker.slash.fill" : "speaker.fill")
                }
                .buttonStyle(.borderless)
                .disabled(model.isProtected(process.bundleID))
                .help(model.isMuted(process.bundleID) ? "Unmute" : "Mute")

                Slider(
                    value: Binding(
                        get: { Double(model.gain(for: process.bundleID)) },
                        set: { model.setGain(Float($0), for: process.bundleID) }
                    ),
                    in: 0...Double(GainStage.maxGain)
                )
                .disabled(model.isMuted(process.bundleID) || model.isProtected(process.bundleID))
            }

            if let failure = model.failure(for: process.bundleID) {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var percentLabel: String {
        if model.isMuted(process.bundleID) { return "muted" }
        return "\(Int((model.gain(for: process.bundleID) * 100).rounded()))%"
    }

    @ViewBuilder
    private var icon: some View {
        if let image = NSRunningApplication(processIdentifier: process.pid)?.icon {
            Image(nsImage: image).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed").frame(width: 16, height: 16)
        }
    }
}
