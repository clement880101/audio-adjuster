# Audio Adjuster

Per-app volume control for macOS, plus a manual anti-duck switch for the volume drop
macOS applies to other audio during FaceTime calls.

Menu bar only — no Dock icon, no window.

## Requirements

macOS 14.2+ (Core Audio process taps). Built and tested on macOS 26.4 with the Swift 6.3
Command Line Tools; no Xcode needed.

## Build

```
make app      # builds build/AudioAdjuster.app
make run      # builds and launches it
make test     # 44 unit tests
```

On first launch macOS asks for audio-recording permission. That is what process taps are
gated behind — the app reads each app's audio in order to play it back at your chosen
volume, and records nothing.

Because there is no Developer ID available, the bundle is ad-hoc signed. macOS keys the
permission grant to the code signature, so **the prompt reappears after most rebuilds**.

## How it works

macOS has no per-app volume API. For each app you actually move a slider on, the app
creates one private Core Audio process tap with `CATapMutedWhenTapped`, wraps it in a
private aggregate device on your current output, and runs an IO proc that applies gain to
the tapped frames and writes them to the speakers.

`CATapMutedWhenTapped` means the app plays normally until our IO proc reads the tap, and
returns to normal the instant we stop. Releasing the tap is therefore a complete restore.

**Apps you never touch are never tapped.** Nothing about their audio path changes.

## Anti-duck

There is no supported macOS API to switch off the ducking another app causes; every
ducking API in the SDK is the knob the *calling* app sets on itself. So anti-duck is a
preset on the same gain engine: it boosts other apps back up and pulls the call app down.
Defaults are in `AntiDuckPreset.default`.

## Layout

| Path | Purpose |
|---|---|
| `Sources/AudioAdjusterKit/GainStage.swift` | Ramped gain and soft clip. The only code on the audio thread. |
| `Sources/AudioAdjusterKit/AppAudioChannel.swift` | Tap + aggregate device + IO proc for one app. |
| `Sources/AudioAdjusterKit/ChannelCoordinator.swift` | Keeps live channels in step with settings and running apps. |
| `Sources/AudioAdjusterKit/AudioProcessRegistry.swift` | Lists apps making sound. |
| `Sources/AudioAdjusterKit/Settings.swift` | Persisted per-app gains and the anti-duck preset. |
| `Sources/AudioAdjusterApp/` | Menu bar UI. |
| `Sources/AudioAdjusterProbe/` | Headless harness for verifying the audio path. |
| `docs/superpowers/specs/` | Design document. |

## Probe

Verifying the audio path without the UI:

```
.build/release/AudioAdjusterProbe --list                          # read-only
.build/release/AudioAdjusterProbe --gain com.apple.Music 0.3 10   # changes what you hear
```

`--gain` restores the app on exit, including on Ctrl-C.

## Status

Built and unit tested; **not yet verified against live audio**. See the design document
for the open question of whether the aggregate device also sidesteps system ducking.
