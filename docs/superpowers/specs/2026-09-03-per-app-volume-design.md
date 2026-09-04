# Per-App Volume + Anti-Duck — Design

Date: 2026-09-03
Status: approved

## Problem

macOS offers no per-application volume control, and during a FaceTime call the system
ducks (lowers) all other audio with no user-facing switch to turn it off.

## What we build

A menu bar app that lists every application currently emitting audio and gives each one
a volume slider and a mute button, plus a manual **Anti-duck** toggle that applies a
saved gain preset to counteract call ducking.

## Feasibility findings (verified against the macOS 26.4 SDK on this machine)

| API | Status |
|---|---|
| `kAudioHardwarePropertyProcessObjectList` | present — enumerates audio-emitting processes |
| `kAudioProcessProperty{PID,BundleID,IsRunningOutput}` | present |
| `AudioHardwareCreateProcessTap` / `AudioHardwareDestroyProcessTap` | macOS 14.2+ |
| `CATapMutedWhenTapped = 2` | macOS 13+ — process plays normally until our IOProc reads the tap |
| `kAudioAggregateDeviceTapListKey` = `"taps"` | present |
| `kAudioAggregateDeviceTapAutoStartKey` = `"tapautostart"` | present |
| `kAudioSubTapUIDKey` = `"uid"`, `kAudioSubTapDriftCompensationKey` = `"drift"` | present |
| `kAudioAggregateDeviceIsPrivateKey` = `"private"`, `MainSubDeviceKey` = `"master"` | present |

There is **no supported API to disable ducking imposed by another application**. Every
ducking symbol in the SDK (`AVAudioVoiceProcessingOtherAudioDuckingConfiguration`,
`AUVoiceIOOtherAudioDuckingLevel`) is client-side — the knob FaceTime sets on itself.
CoreAudio exports an undocumented `_AudioDeviceDuck`, but it *applies* ducking rather
than disabling it. We therefore treat anti-duck as a gain preset on the same engine:
boost the ducked apps back up, and/or pull the call app down.

## Architecture — per-app tap, opt-in

For each app the user actually adjusts, create exactly one private process tap, one
private aggregate device wrapping the current default output, and one IOProc that reads
the tapped frames, applies gain, and writes them to the output. Apps the user never
touches never enter our audio path.

Rejected alternatives:

- **One global tap** muting everything and mixing the whole system. Total control, but a
  crash silences the entire machine and it adds latency to all audio unconditionally.
- **Virtual HAL driver** (BackgroundMusic/eqMac approach). Most robust, survives our
  crashing, but it is a system extension requiring a Developer ID and a notarized
  installer. No signing identity is available, so it is out of reach today.

Because `CATapMutedWhenTapped` only mutes the app's own path *while* our IOProc is
reading, "stop reading" is a complete, automatic restore. That is the core safety
property of this design.

## Components

### `GainStage` (pure, no CoreAudio)
Applies gain to a float buffer, ramping from the current value to the target across the
buffer to avoid zipper noise, with a soft clip above unity (anti-duck requires boosting
past 1.0). Allocation-free and lock-free: it is the only code that runs on the audio
thread. Fully unit tested.

### `AudioProcessRegistry`
Enumerates the process object list, reads PID / bundle ID / isRunningOutput for each,
joins to `NSRunningApplication` for display name and icon, and publishes a deduped,
sorted list. Listens for list changes so entries appear and disappear as apps start and
stop making sound. Sits behind a `CoreAudioSource` protocol so the diffing logic is
tested against a fake.

### `AppAudioChannel`
One per adjusted app. Owns exactly one tap, one aggregate device, and one IOProc, and is
the only type that calls mutating CoreAudio API.

- `attach()`: create tap -> read `kAudioTapPropertyFormat` -> create aggregate device
  with that tap in its tap list and the default output as main sub-device -> create
  IOProc -> start.
- `detach()`: stop -> destroy IOProc -> destroy aggregate -> destroy tap, in that order.
- Any failure mid-`attach()` unwinds everything already built and leaves the app at
  unity gain rather than half-configured.

Created lazily on the first slider move away from 100%; torn down on return to 100%.

### `SettingsStore`
`bundleID -> {gain, muted}` plus the saved anti-duck preset, in UserDefaults. Pure and
tested.

### `MenuBarUI`
SwiftUI `MenuBarExtra` popover: one row per audio-emitting app (icon, name, slider,
mute), and an Anti-duck toggle that applies the saved preset across channels.

## Data flow

Slider -> `SettingsStore` -> channel's target gain (a single aligned `Float` in
preallocated memory) -> the IOProc's next cycle ramps toward it. The UI never blocks on
audio; the audio thread never reads UserDefaults, allocates, or takes a lock.

## Failure and teardown behavior

- Quit tears down every channel in order.
- Default output device change (AirPods connecting) invalidates every aggregate device;
  we observe `kAudioHardwarePropertyDefaultOutputDevice` and rebuild.
- A tapped app quitting removes its process object; that channel is torn down.
- Crash: private taps are owned by our process and are expected to be released by
  `coreaudiod`. **This is an assumption to be verified by test, not a guarantee.**

## Testing

- Unit tests: `GainStage`, `SettingsStore`, anti-duck preset resolution, and registry
  diffing against a fake `CoreAudioSource`.
- `audio-adjuster-probe`: a CLI harness that attaches one channel to one bundle ID with
  no UI, so the audio path can be verified in isolation before any UI exists. This is
  the first thing that touches live audio and is only run with explicit user consent.

## Out of scope for v1

Automatic call detection (anti-duck is a manual preset apply; the hook exists but nothing
watches for calls), microphone/input control, EQ, per-device routing, and anything
requiring a signing identity.

## Known constraints

- Process taps require the audio-capture TCC permission. With no signing identity we can
  only ad-hoc sign, and macOS keys the grant to the code hash, so the permission prompt
  reappears on most rebuilds during development.
- Boosting above unity can clip; `GainStage` soft-clips rather than allowing wraparound.
