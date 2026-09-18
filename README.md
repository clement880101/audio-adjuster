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

## What appears in the list

Only processes that have actually produced sound. Core Audio reports around thirty, most
of them daemons holding an audio client without ever being audible, and listing those
buries the handful worth adjusting.

An app keeps its place after it falls silent, so its volume stays adjustable between
tracks or before it starts. An app that quits is dropped, since there is no longer
anything to tap. Apps you have already adjusted are listed from launch.

Several processes belonging to one app are merged into a single bar — a FaceTime call runs
as both `com.apple.FaceTime` and `com.apple.avconferenced`, and one tap can cover several
process objects. System sound plumbing (`PowerChime`, `systemsoundserverd`) is never
listed.

Command-line audio tools do not appear: they have no bundle identifier, and settings are
keyed by bundle ID so there would be nothing stable to attach them to.

## Volume bars

Each app gets one bar running from 0% to 400%, with **100% at the bar's midpoint**. The
scale is deliberately non-linear: a linear bar would squeeze everyday adjustment — anything
below normal volume — into the first quarter, where a pixel is worth several percent. Half
the bar goes to the range people actually use, half to headroom.

Headroom is not a promise. Audio already near full scale cannot be made louder, and gain
past that only drives the limiter. Most app audio sits well below full scale, which is
where the range earns its keep.

Drag anywhere on a bar to set it; double click to mute.

## Link volumes

With **Link volumes** on — the default — the bars are linked: turning one app up turns the
others down by the same total, so the mix keeps a constant sum. The header shows that
total. Turn it off and each bar moves on its own.

Gains stay absolute — 100% means "as macOS would play it" — so three apps sit at 100% each
rather than 33% each, and opening a fourth app does not quietly make the first three
quieter. Only a deliberate drag moves anything.

The difference is shared equally across the other apps rather than proportionally, which
is more predictable while dragging. An app that reaches silence or the ceiling stops
absorbing and passes its residual to apps that still have room.

Two cases worth knowing:

- **A single app is freely adjustable.** Forcing bars to always sum to 100% would pin a
  lone app at 100% forever, which would remove the ability to simply turn one thing down.
  Linking pushes the *other* apps, so with no others the drag just applies.
- **The total can rise.** If every other app is already silent there is nowhere left to
  take volume from, so the drag still does what was asked and the sum grows.

Mute is never linked, in either mode. It stays the way to silence one app without pushing
volume onto anything else.

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
| `Sources/AudioAdjusterKit/VolumeScale.swift` | Maps a position on a bar to a gain, with 100% at the midpoint. |
| `Sources/AudioAdjusterKit/Balance.swift` | Linked bars: what one app gains, the others give up. |
| `Sources/AudioAdjusterKit/AppAudioChannel.swift` | Tap + aggregate device + IO proc for one app. |
| `Sources/AudioAdjusterKit/ChannelCoordinator.swift` | Keeps live channels in step with settings and running apps. |
| `Sources/AudioAdjusterKit/DuckServo.swift` | Measures call ducking and decides the compensation. |
| `Sources/AudioAdjusterKit/SilenceAudit.swift` | Releases a channel whose tap yields only silence. |
| `Sources/AudioAdjusterKit/AudioProcessRegistry.swift` | Decides what appears in the list. |
| `Sources/AudioAdjusterKit/ProcessGroup.swift` | Merges an app's several audio processes into one entry. |
| `Sources/AudioAdjusterKit/Settings.swift` | Persisted per-app gains, link mode, and which processes carry call audio. |
| `Sources/AudioAdjusterKit/CoreAudioSystem.swift` | Core Audio property reads and process enumeration. |
| `Sources/AudioAdjusterApp/` | Menu bar UI. |
| `Sources/AudioAdjusterProbe/` | Headless harness for verifying the audio path. |
| `site/` | Landing page, deployed to GitHub Pages. |
| `docs/superpowers/specs/` | Design document, with a record of where reality differed. |

## Probe

Core Audio behaviour cannot be unit tested, so there is a headless harness instead. It is
how every audio claim in this README was established.

```sh
AudioAdjusterProbe --list                       # what the app would list. Read-only.
AudioAdjusterProbe --raw                        # every process object, unfiltered, with
                                                # the result of each property read
AudioAdjusterProbe --gain <bundleID> <gain> [s] # tap one app for a while. Changes what
                                                # you hear; restores on exit and Ctrl-C
AudioAdjusterProbe --gain-pid <pid> <gain> [s]  # the same, by pid
AudioAdjusterProbe --verify <pid> <out>         # gain sweep, reporting measured peaks
AudioAdjusterProbe --servo <pid> <out>          # the duck compensation loop, converging
AudioAdjusterProbe --selfduck <pid> <out>       # measures whether our own output is ducked
AudioAdjusterProbe --geometry <pid> <out>       # tap format and IO buffer layout
AudioAdjusterProbe --call-diag <out>            # which processes are audible, and whether
                                                # a tap can capture each. Unmuted, so it is
                                                # safe to run during a call
```

Modes taking an `<out>` path write there instead of stdout, so they can be launched with
`open -a` — see below for why that matters.

## Permissions

Process taps require the `kTCCServiceAudioCapture` grant, and macOS only attaches it to a
process with a bundle identity, prompting only when the app is its own responsible process.
Launch through LaunchServices rather than running the binary directly:

```sh
open -a build/AudioAdjuster.app
```

Without the grant a tap is created successfully and delivers buffers of digital silence
rather than returning an error. `SilenceAudit` detects that and releases the channel, so an
app cannot be left muted with nothing rendered in its place. `CONTRIBUTING.md` has the
detail.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
