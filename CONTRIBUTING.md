# Contributing

Thanks for taking a look. This is a small project with an unusually fussy subject —
Core Audio's process tap API fails quietly in several ways — so most of the guidance here
is about how to tell whether a change actually works.

## Building

```sh
make test     # unit tests
make app      # assembles build/AudioAdjuster.app
make run      # builds and launches it
```

macOS 14.2 or later. A full Xcode install is not required; the Command Line Tools are
enough, and the Makefile adds the swift-testing search paths that only a CLT install
needs.

## The thing that will waste your afternoon

**A process tap returns digital silence, with no error, when the calling process lacks
the `kTCCServiceAudioCapture` grant.** The tap is created, the format and channel counts
are correct, the IO proc runs and delivers buffers of the right size. They are full of
zeros.

macOS can only attach that grant to a process with a bundle identity, and only prompts
when the app is its own responsible process. A bare SwiftPM executable can never be
granted it, and `Foo.app/Contents/MacOS/Foo` run from a terminal is attributed to the
terminal. Launch through LaunchServices:

```sh
open -a build/AudioAdjuster.app
```

The app defends against this at runtime — `SilenceAudit` releases a channel whose tap
yields silence while its app is playing — but during development it is worth recognising
directly.

## Verifying audio changes

Unit tests cover everything that can be tested without hardware: gain, balancing, the
duck servo, the process registry, settings. Anything touching Core Audio cannot be, so
there is a headless harness instead:

```sh
.build/release/AudioAdjusterProbe --list                       # read-only
.build/release/AudioAdjusterProbe --verify <pid> /tmp/out.txt  # gain sweep, measured
.build/release/AudioAdjusterProbe --servo  <pid> /tmp/out.txt  # duck compensation loop
```

Claims about audio behaviour in this project are measured, not assumed, and pull requests
that change the audio path should say what was measured. "Output peak tracked requested
gain linearly across 0.0–4.0" is a review-able claim; "works on my machine" is not.

There is also a debug log, off unless `AUDIOADJUSTER_DEBUG=1` or the file already exists:

```sh
touch ~/Library/Logs/AudioAdjuster-debug.log
```

It records list changes and layout measurements. The app is ad-hoc signed, so its
`os_log` output does not reach the system log store — this exists because of that.

## Real-time safety

`GainStage` and `AppAudioChannel.render` run on the Core Audio IO thread. No allocation,
no locks, no Swift object access, nothing that can block. If a change adds any of those
to that path, it is a bug even when it sounds fine.

## Style

Match the surrounding code. Comments explain why something is the way it is, especially
where the reason is a measurement or a platform quirk that would otherwise look arbitrary.

## Licensing

Contributions are accepted under the Apache License 2.0, the same terms as the project.
