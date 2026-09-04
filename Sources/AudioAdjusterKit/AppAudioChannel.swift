import CoreAudio
import Foundation
import os

/// Owns the entire Core Audio object graph for one application's volume.
///
/// Exactly one tap, one aggregate device and one IO proc. This is the only type in the
/// project that calls mutating Core Audio API.
///
/// The tap uses `CATapMutedWhenTapped`, so the tapped app plays normally until our IO
/// proc starts reading and returns to normal the moment we stop. Tearing this object down
/// is therefore a complete restore, and there is no state left behind to repair.
public final class AppAudioChannel {

    /// Gain state shared with the IO thread.
    ///
    /// Kept in manually allocated memory rather than a Swift property so the render block
    /// captures a trivial pointer and touches no reference-counted object on the audio
    /// thread. Both fields are naturally aligned 32-bit values, so the single-writer /
    /// single-reader access here cannot tear.
    struct IOState {
        var targetGain: Float
        var currentGain: Float
    }

    public let bundleID: String
    private let processObjectID: AudioObjectID
    private let log = Logger(subsystem: "com.audioadjuster", category: "channel")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    private let state: UnsafeMutablePointer<IOState>

    public var isAttached: Bool { tapID != AudioObjectID(kAudioObjectUnknown) }

    public init(bundleID: String, processObjectID: AudioObjectID, gain: Float) {
        self.bundleID = bundleID
        self.processObjectID = processObjectID
        self.state = UnsafeMutablePointer<IOState>.allocate(capacity: 1)
        // Start the ramp at the target so attaching does not fade in from silence.
        let clamped = GainStage.clampGain(gain)
        self.state.initialize(to: IOState(targetGain: clamped, currentGain: clamped))
    }

    deinit {
        detach()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    /// Updates the gain. Safe to call from the UI thread while audio is running.
    public func setGain(_ gain: Float) {
        state.pointee.targetGain = GainStage.clampGain(gain)
    }

    public var gain: Float { state.pointee.targetGain }

    // MARK: - Lifecycle

    /// Builds tap -> aggregate device -> IO proc and starts audio.
    ///
    /// Any failure unwinds everything already created, so the app is left playing at its
    /// normal volume rather than half-configured.
    public func attach(outputDeviceUID: String) throws {
        guard !isAttached else { return }
        do {
            try createTap()
            try createAggregateDevice(outputDeviceUID: outputDeviceUID)
            try createIOProc()
            try start()
        } catch {
            log.error("attach failed for \(self.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            detach()
            throw error
        }
    }

    /// Tears the graph down in reverse order, restoring the app's normal audio path.
    ///
    /// Deliberately total and error-tolerant: this runs on quit and during error unwind,
    /// where giving up partway would leave an app muted.
    public func detach() {
        if isRunning, let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            isRunning = false
        }
        if let proc = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Construction steps

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "AudioAdjuster-\(bundleID)"
        description.uuid = UUID()
        // Private: visible only to us, so nothing else can latch onto this app's audio.
        description.isPrivate = true
        // The app keeps playing normally until our IO proc reads the tap.
        description.muteBehavior = .mutedWhenTapped

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "create process tap for \(bundleID)")
        }
        tapID = id
        tapUUID = description.uuid
    }

    private func createAggregateDevice(outputDeviceUID: String) throws {
        let uuidString = tapUUID.uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioAdjuster \(bundleID)",
            kAudioAggregateDeviceUIDKey: "com.audioadjuster.aggregate.\(uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            // Private so it never appears in Sound settings or Audio MIDI Setup.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: uuidString,
            ]],
        ]

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "create aggregate device for \(bundleID)")
        }
        aggregateID = id
    }

    private func createIOProc() throws {
        let statePointer = state
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inputData, _, outputData, _ in
            AppAudioChannel.render(state: statePointer, input: inputData, output: outputData)
        }
        guard status == noErr, let procID else {
            throw CoreAudioError(status: status, operation: "create IO proc for \(bundleID)")
        }
        ioProcID = procID
    }

    private func start() throws {
        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: "start audio for \(bundleID)")
        }
        isRunning = true
    }

    // MARK: - Render

    /// Copies tapped audio to the output device with gain applied.
    ///
    /// Runs on the Core Audio IO thread. No allocation, no locks, no Swift object access:
    /// only the passed-in pointer, `GainStage` (a trivial struct), and `memcpy`/`memset`.
    private static func render(
        state: UnsafeMutablePointer<IOState>,
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

        let target = state.pointee.targetGain
        var stage = GainStage(current: state.pointee.currentGain)
        let sampleSize = MemoryLayout<Float>.size

        for index in 0..<outputBuffers.count {
            let outputBuffer = outputBuffers[index]
            guard let outputData = outputBuffer.mData else { continue }
            let outputSamples = Int(outputBuffer.mDataByteSize) / sampleSize

            // Nothing tapped for this channel. Write silence rather than leaving whatever
            // the device last had in the buffer.
            guard index < inputBuffers.count, let inputData = inputBuffers[index].mData else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputSamples = Int(inputBuffers[index].mDataByteSize) / sampleSize
            let count = min(inputSamples, outputSamples)
            let destination = outputData.assumingMemoryBound(to: Float.self)

            memcpy(destination, inputData, count * sampleSize)
            // The increment is derived per buffer, so channels of equal length ramp
            // identically and a short buffer still completes its ramp.
            let increment = stage.increment(toward: target, frameCount: count)
            stage.apply(to: destination, frameCount: count, increment: increment)

            if outputSamples > count {
                memset(destination + count, 0, (outputSamples - count) * sampleSize)
            }
        }

        stage.commit(toward: target)
        state.pointee.currentGain = stage.current
    }
}
