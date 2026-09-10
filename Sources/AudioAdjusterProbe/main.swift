import AppKit
import AudioAdjusterKit
import CoreAudio
import Foundation

/// Headless harness for verifying the audio path without any UI.
///
///   AudioAdjusterProbe --list                     read-only; touches no audio
///   AudioAdjusterProbe --gain <bundleID> <gain> [seconds]
///
/// `--gain` creates a real tap and changes what you hear. It restores the app on exit,
/// including on Ctrl-C.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    usage:
      AudioAdjusterProbe --list
      AudioAdjusterProbe --gain <bundleID> <gain 0.0-2.0> [seconds, default 10]
    """)
    exit(2)
}

let system = CoreAudioSystem()
let registry = AudioProcessRegistry(source: system, names: RunningAppNameResolver())

switch arguments.first {
case "--list":
    registry.refresh()
    let deviceDescription: String
    do {
        let deviceID = try CoreAudioSystem.defaultOutputDeviceID()
        deviceDescription = "\(try CoreAudioSystem.deviceUID(deviceID)) (id \(deviceID))"
    } catch {
        deviceDescription = "unavailable: \(error)"
    }
    print("default output: \(deviceDescription)")
    print("")
    print("playing  pid      bundle id                              name")
    for process in registry.processes {
        print(String(
            format: "%-8@ %-8d %-38@ %@",
            process.isPlaying ? "yes" : "-",
            process.pid,
            process.bundleID as NSString,
            process.name as NSString
        ))
    }

case "--raw":
    // Diagnostic: unfiltered process objects with the raw result of every property read,
    // so an empty list can be told apart from a permission or filtering problem.
    do {
        let ids = try CoreAudioProperty.array(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList,
            of: AudioObjectID.self,
            operation: "read process object list"
        )
        print("process objects: \(ids.count)")
        for id in ids {
            let pid = try? CoreAudioProperty.value(id, kAudioProcessPropertyPID, default: pid_t(-1), operation: "pid")
            var bundle = "<none>"
            do {
                bundle = try CoreAudioProperty.string(id, kAudioProcessPropertyBundleID, operation: "bundle")
            } catch let error as CoreAudioError {
                bundle = "<err \(error.status)>"
            }
            let running: UInt32 = (try? CoreAudioProperty.value(id, kAudioProcessPropertyIsRunning, default: 0, operation: "r")) ?? 9
            let output: UInt32 = (try? CoreAudioProperty.value(id, kAudioProcessPropertyIsRunningOutput, default: 0, operation: "o")) ?? 9
            let name = pid.map { NSRunningApplication(processIdentifier: $0)?.localizedName ?? "-" } ?? "-"
            print("  obj=\(id) pid=\(pid.map(String.init) ?? "?") running=\(running) output=\(output) bundle=\(bundle) name=\(name)")
        }
    } catch {
        print("failed: \(error)")
        exit(1)
    }

case "--selfduck":
    // Measures whether OUR OWN re-rendered output is ducked by the system.
    //
    // Channel A takes a muted tap on the target and renders it normally, so we are
    // putting audio on the device like the real app does. Channel B then takes an
    // UNMUTED tap on this very process at gain 0 - it writes silence, so it adds nothing
    // audible, and reports only the pre-gain peak of what we are placing on the device.
    //
    // If B's input peak matches A's, our output is not ducked. If it is roughly 30x
    // lower, the system is ducking us and gain compensation cannot win.
    guard arguments.count >= 3, let duckPID = pid_t(arguments[1]) else { usage() }
    let duckPath = arguments[2]
    var duckReport = "selfduck: target pid \(duckPID), own pid \(getpid())\n"

    if let duckEntry = system.rawProcesses().first(where: { $0.pid == duckPID }) {
        let renderChannel = AppAudioChannel(
            bundleID: duckEntry.bundleID ?? "pid-\(duckPID)",
            processObjectID: duckEntry.objectID,
            gain: arguments.count > 3 ? (Float(arguments[3]) ?? 1.0) : 1.0,
            options: .init(allowUnlimitedGain: true)
        )
        do {
            let uid = try CoreAudioSystem.deviceUID(CoreAudioSystem.defaultOutputDeviceID())
            try renderChannel.attach(outputDeviceUID: uid)
            Thread.sleep(forTimeInterval: 2.0)
            let renderStatistics = renderChannel.readStatistics()
            duckReport += String(format: "A: rendering target - inputPeak=%.4f outputPeak=%.4f\n",
                                 renderStatistics.inputPeak, renderStatistics.peak)

            // Our own process now appears in the process list because we are producing audio.
            if let selfEntry = system.rawProcesses().first(where: { $0.pid == getpid() }) {
                let observeChannel = AppAudioChannel(
                    bundleID: "self-observer",
                    processObjectID: selfEntry.objectID,
                    gain: 0.0,
                    options: .init(muteBehavior: .unmuted, isPrivate: true)
                )
                try observeChannel.attach(outputDeviceUID: uid)
                Thread.sleep(forTimeInterval: 2.0)
                let observeStatistics = observeChannel.readStatistics()
                observeChannel.detach()
                duckReport += String(format: "B: observing ourselves - inputPeak=%.4f frames=%llu\n",
                                     observeStatistics.inputPeak, observeStatistics.frames)
                let ratio = renderStatistics.peak > 0 ? observeStatistics.inputPeak / renderStatistics.peak : 0
                duckReport += String(format: "ratio B/A = %.4f  -> %@\n", ratio,
                                     (ratio > 0.5 ? "OUR OUTPUT IS NOT DUCKED" :
                                      ratio > 0 ? "OUR OUTPUT IS DUCKED" : "inconclusive") as NSString)
            } else {
                duckReport += "B: our own process object not found\n"
            }
            renderChannel.detach()
        } catch {
            duckReport += "attach failed: \(error)\n"
        }
    } else {
        duckReport += "target process not found\n"
    }
    try? duckReport.write(toFile: duckPath, atomically: true, encoding: .utf8)

case "--call-diag":
    // Safe to run during a live call: every tap here is UNMUTED, so nothing about the
    // call's audio changes. Finds which processes are actually producing sound and
    // whether a tap can capture each one.
    let callPath = arguments.count >= 2 ? arguments[1] : "/tmp/call-diag.txt"
    var callReport = "call diagnostic\n"
    let candidates = system.rawProcesses().filter { $0.isRunningOutput && $0.pid != getpid() }
    callReport += "processes producing output: \(candidates.count)\n"

    if candidates.isEmpty {
        callReport += "  (none - is audio actually playing right now?)\n"
    }
    for candidate in candidates {
        let name = candidate.pid > 0
            ? (NSRunningApplication(processIdentifier: candidate.pid)?.localizedName ?? "-")
            : "-"
        let callChannel = AppAudioChannel(
            bundleID: candidate.bundleID ?? "pid-\(candidate.pid)",
            processObjectID: candidate.objectID,
            gain: 1.0,
            options: .init(muteBehavior: .unmuted, isPrivate: true)
        )
        var line = String(format: "  pid=%-7d %-34@ %@",
                          candidate.pid,
                          (candidate.bundleID ?? "<none>") as NSString,
                          name as NSString)
        do {
            let uid = try CoreAudioSystem.deviceUID(CoreAudioSystem.defaultOutputDeviceID())
            try callChannel.attach(outputDeviceUID: uid)
            Thread.sleep(forTimeInterval: 2.0)
            let statistics = callChannel.readStatistics()
            let geometry = callChannel.renderGeometry()
            callChannel.detach()
            line += String(format: " frames=%llu peak=%.4f", statistics.frames, statistics.peak)
            if let geometry {
                line += " in=\(geometry.inputChannels)ch out=\(geometry.outputChannels)ch"
            }
            line += statistics.peak > 0 ? "  <- CAPTURED" : "  <- SILENT (tap cannot see this audio)"
        } catch {
            line += " attach failed: \(error)"
        }
        callReport += line + "\n"
    }
    try? callReport.write(toFile: callPath, atomically: true, encoding: .utf8)

case "--geometry":
    // Reports the tap format alongside the actual buffer layout the IO proc sees, plus a
    // fidelity check: with gain 1.0 the rendered peak should match the source's own peak.
    guard arguments.count >= 3, let geoPID = pid_t(arguments[1]) else { usage() }
    let geoPath = arguments[2]
    var geoReport = "geometry: target pid \(geoPID)\n"

    if let geoEntry = system.rawProcesses().first(where: { $0.pid == geoPID }) {
        let geoChannel = AppAudioChannel(
            bundleID: geoEntry.bundleID ?? "pid-\(geoPID)",
            processObjectID: geoEntry.objectID,
            gain: 1.0
        )
        do {
            let uid = try CoreAudioSystem.deviceUID(CoreAudioSystem.defaultOutputDeviceID())
            try geoChannel.attach(outputDeviceUID: uid)
            if let format = geoChannel.tapFormat() {
                let interleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
                geoReport += "tap format: \(Int(format.mSampleRate))Hz channels=\(format.mChannelsPerFrame) "
                geoReport += "bits=\(format.mBitsPerChannel) bytesPerFrame=\(format.mBytesPerFrame) "
                geoReport += "interleaved=\(interleaved) flags=\(format.mFormatFlags)\n"
            }
            let counts = geoChannel.aggregateChannelCounts()
            geoReport += "aggregate channels: in=\(counts.input) out=\(counts.output)\n"
            Thread.sleep(forTimeInterval: 2.0)
            if let geometry = geoChannel.renderGeometry() {
                geoReport += "render input:  buffers=\(geometry.inputBuffers) channelsPerBuffer=\(geometry.inputChannelsPerBuffer) bytes=\(geometry.inputBytesPerBuffer)\n"
                geoReport += "render output: buffers=\(geometry.outputBuffers) channelsPerBuffer=\(geometry.outputChannelsPerBuffer) bytes=\(geometry.outputBytesPerBuffer)\n"
                geoReport += "total channels in=\(geometry.inputChannels) out=\(geometry.outputChannels) mismatched=\(geometry.isMismatched)\n"
            } else {
                geoReport += "IO proc never ran\n"
            }
            let statistics = geoChannel.readStatistics()
            geoReport += String(format: "frames=%llu peak=%.4f\n", statistics.frames, statistics.peak)
            geoChannel.detach()
        } catch {
            geoReport += "attach failed: \(error)\n"
        }
    } else {
        geoReport += "target process not found\n"
    }
    try? geoReport.write(toFile: geoPath, atomically: true, encoding: .utf8)

case "--verify":
    // End-to-end check of the shipping configuration: a private, mutedWhenTapped tap at a
    // sweep of gains. If the measured peak tracks the requested gain, the whole path works.
    guard arguments.count >= 3, let verifyPID = pid_t(arguments[1]) else { usage() }
    let verifyPath = arguments[2]
    var verifyReport = "verify: target pid \(verifyPID)\n"

    if let verifyEntry = system.rawProcesses().first(where: { $0.pid == verifyPID }) {
        for testGain in [Float(1.0), 0.5, 0.25, 0.0, 2.0] {
            let verifyChannel = AppAudioChannel(
                bundleID: verifyEntry.bundleID ?? "pid-\(verifyPID)",
                processObjectID: verifyEntry.objectID,
                gain: testGain
            )
            do {
                let uid = try CoreAudioSystem.deviceUID(CoreAudioSystem.defaultOutputDeviceID())
                try verifyChannel.attach(outputDeviceUID: uid)
                Thread.sleep(forTimeInterval: 1.5)
                let statistics = verifyChannel.readStatistics()
                verifyChannel.detach()
                verifyReport += String(format: "  gain=%.2f frames=%llu peak=%.4f\n", testGain, statistics.frames, statistics.peak)
            } catch {
                verifyReport += "  gain=\(testGain) attach failed: \(error)\n"
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    } else {
        verifyReport += "target process not found\n"
    }
    try? verifyReport.write(toFile: verifyPath, atomically: true, encoding: .utf8)

case "--tap-diag-file":
    // Same diagnostic as --tap-diag but writes to a file, so it can be launched through
    // LaunchServices (`open`) where the app is its own responsible process and macOS can
    // therefore show the audio-capture prompt.
    guard arguments.count >= 3, let filePID = pid_t(arguments[1]) else { usage() }
    let outputPath = arguments[2]
    var report = "probe pid \(getpid()), target pid \(filePID)\n"

    if let fileEntry = system.rawProcesses().first(where: { $0.pid == filePID }) {
        let fileChannel = AppAudioChannel(
            bundleID: fileEntry.bundleID ?? "pid-\(filePID)",
            processObjectID: fileEntry.objectID,
            gain: 1.0,
            options: .init(muteBehavior: .unmuted, isPrivate: true)
        )
        do {
            let uid = try CoreAudioSystem.deviceUID(CoreAudioSystem.defaultOutputDeviceID())
            try fileChannel.attach(outputDeviceUID: uid)
            Thread.sleep(forTimeInterval: 3.0)
            let statistics = fileChannel.readStatistics()
            fileChannel.detach()
            report += String(format: "frames=%llu peak=%.4f\n", statistics.frames, statistics.peak)
        } catch {
            report += "attach failed: \(error)\n"
        }
    } else {
        report += "target process not found\n"
    }
    try? report.write(toFile: outputPath, atomically: true, encoding: .utf8)

case "--tap-diag":
    // Tries each tap configuration against one process and reports whether audio arrives.
    // Uses an unmuted tap for the first variants so the source keeps playing normally.
    guard arguments.count >= 2, let diagPID = pid_t(arguments[1]) else { usage() }
    guard let diagEntry = system.rawProcesses().first(where: { $0.pid == diagPID }) else {
        print("no audio process with pid \(diagPID); is it playing?")
        exit(1)
    }
    print("process object \(diagEntry.objectID) for pid \(diagPID), bundle \(diagEntry.bundleID ?? "<none>")")

    let variants: [(String, AppAudioChannel.TapOptions)] = [
        ("unmuted + private", .init(muteBehavior: .unmuted, isPrivate: true)),
        ("unmuted + public", .init(muteBehavior: .unmuted, isPrivate: false)),
        ("mutedWhenTapped + private", .init(muteBehavior: .mutedWhenTapped, isPrivate: true)),
    ]

    for (label, options) in variants {
        let diagChannel = AppAudioChannel(
            bundleID: diagEntry.bundleID ?? "pid-\(diagPID)",
            processObjectID: diagEntry.objectID,
            gain: 1.0,
            options: options
        )
        do {
            let uid = try CoreAudioSystem.deviceUID(CoreAudioSystem.defaultOutputDeviceID())
            try diagChannel.attach(outputDeviceUID: uid)
        } catch {
            print("  \(label): attach failed: \(error)")
            continue
        }
        let format = diagChannel.tapFormat()
        let counts = diagChannel.aggregateChannelCounts()
        Thread.sleep(forTimeInterval: 1.5)
        let statistics = diagChannel.readStatistics()
        diagChannel.detach()
        let formatText = format.map {
            "\(Int($0.mSampleRate))Hz ch=\($0.mChannelsPerFrame) bits=\($0.mBitsPerChannel) fmt=\($0.mFormatID)"
        } ?? "<none>"
        print(String(
            format: "  %-28@ tap[%@] agg[in=%d out=%d] frames=%llu peak=%.4f",
            label as NSString, formatText as NSString, counts.input, counts.output,
            statistics.frames, statistics.peak
        ))
    }

case "--gain-pid":
    // Attaches by PID instead of bundle ID, so the audio path can be verified against a
    // process we started ourselves rather than one of the user's apps.
    guard arguments.count >= 3, let targetPID = pid_t(arguments[1]), let gain = Float(arguments[2]) else { usage() }
    let duration = arguments.count > 3 ? (Double(arguments[3]) ?? 6) : 6

    guard let entry = system.rawProcesses().first(where: { $0.pid == targetPID }) else {
        print("no audio process with pid \(targetPID); is it playing?")
        exit(1)
    }

    let pidChannel = AppAudioChannel(
        bundleID: entry.bundleID ?? "pid-\(targetPID)",
        processObjectID: entry.objectID,
        gain: gain
    )

    do {
        let uid = try CoreAudioSystem.deviceUID(CoreAudioSystem.defaultOutputDeviceID())
        try pidChannel.attach(outputDeviceUID: uid)
        print("attached to pid \(targetPID) (object \(entry.objectID)) at gain \(gain), output \(uid)")
    } catch {
        print("attach failed: \(error)")
        exit(1)
    }

    // Sample the render statistics so we can see whether audio genuinely flows through
    // our IO proc, rather than only that the graph was built.
    var elapsed = 0.0
    while elapsed < duration {
        Thread.sleep(forTimeInterval: 0.5)
        elapsed += 0.5
        let statistics = pidChannel.readStatistics()
        print(String(format: "  t=%.1fs frames=%llu peak=%.4f", elapsed, statistics.frames, statistics.peak))
    }
    pidChannel.detach()
    print("detached; pid \(targetPID) restored")

case "--gain":
    guard arguments.count >= 3, let gain = Float(arguments[2]) else { usage() }
    let bundleID = arguments[1]
    let seconds = arguments.count > 3 ? (Double(arguments[3]) ?? 10) : 10

    registry.refresh()
    guard let process = registry.processes.first(where: { $0.bundleID == bundleID }) else {
        print("no audio process with bundle id \(bundleID); run --list")
        exit(1)
    }

    let channel = AppAudioChannel(bundleID: bundleID, processObjectID: process.objectID, gain: gain)

    // Restore the app's audio on Ctrl-C as well as on normal exit; leaving a tap running
    // would leave the app muted.
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        channel.detach()
        print("\nrestored \(bundleID)")
        exit(0)
    }
    signal(SIGINT, SIG_IGN)
    source.resume()

    do {
        let uid = try CoreAudioSystem.deviceUID(CoreAudioSystem.defaultOutputDeviceID())
        try channel.attach(outputDeviceUID: uid)
        print("controlling \(process.name) at gain \(gain) for \(seconds)s (Ctrl-C to stop early)")
    } catch {
        print("failed: \(error)")
        exit(1)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        channel.detach()
        print("restored \(bundleID)")
        exit(0)
    }
    dispatchMain()

default:
    usage()
}
