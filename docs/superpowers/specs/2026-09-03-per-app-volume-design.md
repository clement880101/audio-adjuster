# Per-App Volume + Anti-Duck — Design

Date: 2026-09-03
Status: implemented — see "What changed during implementation" at the end

This is the design as agreed before building. It is kept as written, because the record of
what we expected is worth having next to what turned out to be true. Every point where
reality differed is listed at the end rather than edited in above.

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


---

## What changed during implementation

Written after the fact. The architecture above survived; the anti-duck design did not.

### Anti-duck was not an open question in the end — it was measured

The spec treats "does the aggregate device sidestep ducking" as the open question. It does
not, and the real behaviour is more useful. Measured on a live FaceTime call, against a
test tone whose un-ducked peak is 0.0275:

| measurement | peak |
|---|---|
| test tone, no call | 0.0275 |
| captured via an **unmuted** tap, during a call | 0.0009 |
| captured via **mutedWhenTapped**, during a call | 0.0275 |
| our own rendered output, observed back | ratio 0.0334 |

A muted tap captures audio *before* ducking. Our own output is then ducked in turn, by the
same ~0.033. Ducking is a clean linear attenuation, linear well past full scale — rendered
peaks of 0.82 / 1.65 / 3.29 came back as 0.0277 / 0.0557 / 0.1115 — so it can be inverted
exactly rather than approximated.

`DuckServo` measures the ratio live, by attaching an unmuted silent tap to our own process
and comparing what we wrote with what reached the device. Convergence on a real call:
29.2× → 31.4× → 31.6×, output settling at 0.0275 against an un-ducked 0.0275.

### The call app must be compensated, not protected

The spec has no notion of a protected app. Implementation first added one, because tapping
the call engine made calls *quieter*: a call is exempt from ducking until we re-render it,
at which point it becomes ordinary audio and is ducked. That block was later lifted, since
compensation cancels exactly that attenuation. A tapped call engine is always compensated
— not as a feature, but because without it the control does harm rather than nothing.

### Anti-duck is not user-facing

`AntiDuckPreset` and its toggle are gone. Compensation applies only to call channels, and
only while a call is producing audio. It is a correction, not a feature.

### Volume bars are linked, and the range runs to 400%

Not in the spec at all. Raising one app lowers the others by the same total, with a switch
to turn that off. The range runs to 4× on a non-linear bar with 100% at the midpoint, so
everyday adjustment keeps half the bar.

### The listing rule changed twice

The spec says "every application currently emitting audio". Implementation first listed
anything macOS could name, which surfaced seventeen entries, most of them daemons. Then
anything with a Dock icon, which still admitted some and excluded audible oddities. The
rule that stuck: only processes that have actually produced sound, remembered after they
fall silent, with system sound plumbing excluded outright.

Processes are also grouped: a FaceTime call runs as both `com.apple.FaceTime` and
`com.apple.avconferenced`, and one tap covers several process objects, so it stays one
control.

### The trap the spec did not anticipate

**A process tap returns digital silence, with no error, when the process lacks the
`kTCCServiceAudioCapture` grant.** The tap is created, the format and channel counts are
right, the IO proc runs and delivers correctly sized buffers of zeros. macOS only attaches
that grant to a process with a bundle identity, and only prompts when the app is its own
responsible process — so a bare SwiftPM executable can never obtain it.

Because the tap also *mutes* the source, the failure mode is an app that goes silent for
no visible reason. `SilenceAudit` exists entirely because of this.

### Still true

The per-app opt-in tap architecture, `CATapMutedWhenTapped` as the restore mechanism, the
unwinding attach, the rebuild on default-device change, and the real-time constraints on
the render path all held up unchanged.
