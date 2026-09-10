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
ducking API in the SDK is the knob the *calling* app sets on itself. What made this
possible instead was measuring what ducking actually does, on a live FaceTime call:

| measurement | peak |
|---|---|
| test tone, no call | 0.0275 |
| captured via **unmuted** tap, during call | 0.0009 |
| captured via **mutedWhenTapped**, during call | 0.0275 |
| our own rendered output, observed back | ratio 0.0334 |

Two facts follow. A muted tap captures audio *before* ducking is applied. And the system
then ducks *our* output by the same amount, since during a call we are just "other audio".

So the duck is a linear attenuation of about 0.033 that we can invert: capture pre-duck,
boost by ~30x, and the system's own ducking brings it back to the original level. Core
Audio's float buffers carry values past full scale without clipping (rendered peaks of
0.82 / 1.65 / 3.29 came back as 0.0277 / 0.0557 / 0.1115 — linear throughout), so this
works for loud sources too.

The app measures the ratio live rather than assuming 30x, by attaching an unmuted, silent
tap to itself and comparing what it wrote with what reached the device. Measured
convergence on a real call: 29.2x -> 31.4x -> 31.6x, with observed output settling at
0.0275 against an un-ducked reference of 0.0275.

**The call app is never tapped.** Its audio is exempt from ducking right up until we
re-render it as ours, at which point it gets ducked — so tapping it makes calls quieter,
not louder. `avconferenced`, FaceTime and `TelephonyUtilities` are refused a channel.

### The safety property

Compensation reaches ~30x. If a call ends while that is applied, audio would be 30x too
loud. `DuckServo` is asymmetric about this throughout:

- compensation applies only while a call engine is actively producing audio, checked
  every 200ms;
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

## Status

Per-app volume is verified working against live audio. Anti-duck is implemented as a gain
preset but **its premise is still untested** — whether routing through our aggregate device
also sidesteps the system's call ducking needs checking on a real call.
