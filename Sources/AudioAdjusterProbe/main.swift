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
