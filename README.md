# Audio Adjuster

[![CI](https://github.com/clement880101/audio-adjuster-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/clement880101/audio-adjuster-mac/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14.2%2B-lightgrey.svg)](#requirements)

Per-app volume control for macOS. A menu bar slider for every application that is making
noise, built on Core Audio process taps.

**<https://clement880101.github.io/audio-adjuster-mac>**

Menu bar only — no Dock icon, no window.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/clement880101/audio-adjuster-mac/main/install.sh | sh
```

Or download the latest [release](https://github.com/clement880101/audio-adjuster-mac/releases/latest)
and move the app into /Applications.

On first use macOS asks for audio-recording permission. Process taps are gated behind it —
the app reads each app's audio in order to play it back at your chosen volume, and records
nothing.

The build is **ad-hoc signed, not notarized**: the project has no Apple Developer ID, so
macOS cannot verify who built it and will warn on first launch. Open it the first time
with right-click → Open so you can read that warning and decide, or build from source and
sidestep the question.

## Requirements

macOS 14.2 or later, for Core Audio process taps. Developed on macOS 26.4 with the Swift
6.3 Command Line Tools; a full Xcode install is not required.

## Build

```sh
make app      # assembles build/AudioAdjuster.app
make run      # builds and launches it
make test     # unit tests
make dist     # zipped bundle plus its checksum
```

macOS keys the permission grant to the code signature, so with ad-hoc signing **the
prompt reappears after most rebuilds**.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). It is mostly about how to tell whether a change to
the audio path actually works, since almost none of it can be unit tested.

## How it works

macOS has no per-app volume API. For each app you actually move a slider on, the app
creates one private Core Audio process tap with `CATapMutedWhenTapped`, wraps it in a
private aggregate device on your current output, and runs an IO proc that applies gain to
the tapped frames and writes them to the speakers.

`CATapMutedWhenTapped` means the app plays normally until our IO proc reads the tap, and
returns to normal the instant we stop. Releasing the tap is therefore a complete restore.

**Apps you never touch are never tapped.** Nothing about their audio path changes.

## Balance

With **Balance** on, the sliders are linked: turning one app up turns the others down by
the same total, so the mix keeps a constant sum. The header shows that total.

Gains stay absolute — 100% means "as macOS would play it" — so three apps sit at 100% each
rather than 33% each, and opening a fourth app does not quietly make the first three
quieter. Only a deliberate drag moves anything.

The difference is shared equally across the other apps rather than proportionally, which
is more predictable while dragging. An app that reaches silence or the ceiling stops
absorbing and passes its residual to apps that still have room.

Two cases worth knowing:

- **A single app is freely adjustable.** Forcing sliders to always sum to 100% would pin a
  lone app at 100% forever, which would remove the ability to simply turn one thing down.
  Balancing pushes the *other* apps, so with no others the drag just applies.
- **The total can rise.** If every other app is already silent there is nowhere left to
  take volume from, so the drag still does what was asked and the sum grows.

Call engines never participate: they cannot be tapped at all, so they can neither give nor
take volume.

## Call audio

macOS attenuates every process that is not the call by roughly 0.033 (about -30 dB) while
a call is in progress. A muted tap captures audio *before* that, but our own rendered
output is then ducked in turn — so a tapped call app, which was exempt until we touched
it, would come out drastically quieter.

`DuckServo` measures that attenuation live, by attaching an unmuted, silent tap to this
process and comparing what we wrote with what reached the device, and the coordinator
cancels it on call channels. Measured convergence on a real call: 29.2x -> 31.4x -> 31.6x,
with observed output settling at 0.0275 against an un-ducked reference of 0.0275.

This is not a feature with a switch. It is what makes the call app's volume bar behave at
all, and it applies whenever a call channel exists.

It does **not** stop macOS quietening your other audio during a call. Compensation is
applied only to the call's own channel. Everything else is ducked whether this app taps it
or not, so it is left alone.

### The safety property

Compensation reaches ~30x. If a call ends while that is applied, audio would be 30x too
loud. `DuckServo` is asymmetric about this throughout:

- it applies only while a call engine is actively producing audio, checked every 200ms;
- it rises gradually but falls in a single step;
- it is hard-capped at 40x regardless of measurement;
- unusable or non-finite measurements hold the current value instead of guessing;
- the limiter acts on the user's gain only, never on compensation, which must stay linear
  for the inversion to be exact.

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

## A gotcha that costs hours

**A process tap returns digital silence, with no error, unless the calling process has the
`kTCCServiceAudioCapture` grant.** Everything still appears to work: the tap is created,
the aggregate device reports the right format and channel counts, and the IO proc runs and
delivers buffers of the correct size. They are simply full of zeros.

macOS can only attach that grant to a process with a bundle identity, and it only prompts
when the app is its own responsible process. A bare SwiftPM executable run from a shell can
never be granted it, and a bundled app run as `Foo.app/Contents/MacOS/Foo` from a terminal
is attributed to the terminal instead. Launch it through LaunchServices:

```
open -a build/AudioAdjuster.app
```

Verified with the tap muted and the gain swept: measured output peak tracks requested gain
linearly (1.00 -> 0.0275, 0.50 -> 0.0142, 0.25 -> 0.0069, 0.00 -> 0.0000, 2.00 -> 0.0549
for a source whose unattenuated peak is 0.0275).

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
