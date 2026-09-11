import AppKit
import AudioAdjusterKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DebugLog.write("VIEW body rebuilt with " + model.processes.map {
            "\($0.name)\($0.isPlaying ? "*" : "")"
        }.joined(separator: ", "))
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if model.processes.isEmpty {
                Text("No apps are playing audio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else if model.processes.count > Self.rowsBeforeScrolling {
                // Only past this many apps is a scroller worth the loss of a window that
                // fits its contents. A fixed height here, not a cap: a ScrollView has no
                // intrinsic height, so a window sizing itself to content would collapse it.
                ScrollView {
                    rows
                }
                .frame(height: Self.scrollingHeight)
            } else {
                // The window grows to fit however many apps there are.
                rows
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    /// Above this many apps the list scrolls instead of growing.
    private static let rowsBeforeScrolling = 12
    private static let scrollingHeight: CGFloat = 460

    private var rows: some View {
        VStack(spacing: 6) {
            ForEach(model.processes) { process in
                AppRow(model: model, process: process)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Volume").font(.headline)
            if model.processes.count > 1 {
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                Text("Drag a bar to set volume")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
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
}

/// One app: a single bar you drag to set its volume.
private struct AppRow: View {
    @ObservedObject var model: AppModel
    let process: AudioProcess

    private var isProtected: Bool { model.isProtected(process.bundleID) }
    private var isMuted: Bool { model.isMuted(process.bundleID) }
    private var gain: Float { model.gain(for: process.bundleID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            VolumeBar(
                level: gain,
                isMuted: isMuted,
                isEnabled: !isProtected,
                isPlaying: process.isPlaying,
                onChange: { model.setGain($0, for: process.bundleID) }
            ) {
                HStack(spacing: 7) {
                    icon
                    Text(process.name)
                        .lineLimit(1)
                        .foregroundStyle(isProtected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Spacer(minLength: 4)
                    Text(label)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .onTapGesture(count: 2) {
                // Double click silences one app without pushing volume onto the others.
                guard !isProtected else { return }
                model.toggleMute(process.bundleID)
            }

            if isProtected {
                caption("Call audio — adjusting this makes calls quieter")
            } else if let failure = model.failure(for: process.bundleID) {
                caption(failure).foregroundStyle(.red)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.leading, 2)
    }

    private var label: String {
        if isProtected { return "—" }
        if isMuted { return "muted" }
        return "\(Int((gain * 100).rounded()))%"
    }

    @ViewBuilder
    private var icon: some View {
        if let image = NSRunningApplication(processIdentifier: process.pid)?.icon {
            Image(nsImage: image).resizable().frame(width: 15, height: 15)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 12)).frame(width: 15, height: 15)
        }
    }
}

/// A horizontal bar whose fill is the volume. Dragging anywhere on it sets the level,
/// including a press without movement, so a single click jumps to that position.
///
/// The row's size comes from `content`, not from a `GeometryReader`. A GeometryReader has
/// no intrinsic size of its own, so using one as the sizing container inside a ScrollView
/// lets the row collapse and render as nothing. Here it only measures, in the background.
private struct VolumeBar<Content: View>: View {
    let level: Float
    let isMuted: Bool
    let isEnabled: Bool
    let isPlaying: Bool
    let onChange: (Float) -> Void
    @ViewBuilder let content: Content

    @State private var width: CGFloat = 0

    /// Where 100% sits on a bar that runs to 200%.
    private var unityFraction: CGFloat { CGFloat(1.0 / GainStage.maxGain) }
    private var fraction: CGFloat { min(max(CGFloat(level / GainStage.maxGain), 0), 1) }

    var body: some View {
        content
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(alignment: .leading) { track }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .gesture(
                // minimumDistance 0 so a plain click sets the level too.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled, width > 0 else { return }
                        let position = min(max(value.location.x / width, 0), 1)
                        onChange(Float(position) * GainStage.maxGain)
                    }
            )
            .opacity(isEnabled ? 1 : 0.55)
    }

    private var track: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7).fill(.quaternary)

            RoundedRectangle(cornerRadius: 7)
                .fill(fillStyle)
                .frame(width: max(3, width * fraction))

            // Marks normal volume, so 100% is findable on a bar that goes to 200%.
            Rectangle()
                .fill(.secondary.opacity(0.45))
                .frame(width: 1)
                .padding(.vertical, 5)
                .offset(x: width * unityFraction)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        width = geometry.size.width
                        DebugLog.write("LAYOUT bar width=\(geometry.size.width) height=\(geometry.size.height)")
                    }
                    .onChange(of: geometry.size.width) { _, newWidth in
                        width = newWidth
                        DebugLog.write("LAYOUT bar width changed to \(newWidth)")
                    }
            }
        }
    }

    private var fillStyle: AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(.quaternary) }
        if isMuted { return AnyShapeStyle(.tertiary) }
        return AnyShapeStyle(Color.accentColor.opacity(isPlaying ? 0.85 : 0.45))
    }
}
