# Changelog

## [0.3.0](https://github.com/clement880101/audio-adjuster-mac/compare/audio-adjuster-v0.2.2...audio-adjuster-v0.3.0) (2026-09-19)


### Features

* balance mode - linked volume sliders ([73a6776](https://github.com/clement880101/audio-adjuster-mac/commit/73a6776e408a6d20e197e6a7df4d285d4ec71f50))
* drag bar per app; balance is no longer a mode ([12c2854](https://github.com/clement880101/audio-adjuster-mac/commit/12c28549281acbbe71c1979d9566a4f7cff21871))
* give the app and the site a logo ([d7f95fa](https://github.com/clement880101/audio-adjuster-mac/commit/d7f95faef6aa4ba97a0134f31e272b6b4cfcfd08))
* hide system sound plumbing from the list ([2e9ad2a](https://github.com/clement880101/audio-adjuster-mac/commit/2e9ad2a199ae9c3ebf62ae208ff63c0cdd2de6f4))
* list only what has made a sound, and keep it listed ([90ae350](https://github.com/clement880101/audio-adjuster-mac/commit/90ae350a126952c1661d6d4d7bb3b2d9973595cb))
* menu bar app, probe harness, app bundle ([b824d7c](https://github.com/clement880101/audio-adjuster-mac/commit/b824d7c1a71c43bcb4f8c1333274de03ba825c80))
* name PowerChime and systemsoundserverd ([b4b3b79](https://github.com/clement880101/audio-adjuster-mac/commit/b4b3b79d18bec39d5afaa0a314d1f63e99b14277))
* popover grows to fit the apps listed ([a4c43c3](https://github.com/clement880101/audio-adjuster-mac/commit/a4c43c30f8e0f62f98b1af1ecc144c104fbfe9fd))
* raise the range to 1000% on a logarithmic boost curve ([5c4da6d](https://github.com/clement880101/audio-adjuster-mac/commit/5c4da6d15816eecd724314799486146f749b1683))
* raise the range to 400% on a non-linear bar ([4a253b0](https://github.com/clement880101/audio-adjuster-mac/commit/4a253b0e51a72bf3f38b82f3d8b36cadbf735c90))
* release channels whose tap delivers only silence ([f839b4b](https://github.com/clement880101/audio-adjuster-mac/commit/f839b4bff48d28092da79bf19a589830af4c969f))
* remove the anti-duck option; always-visible Reset all ([6449803](https://github.com/clement880101/audio-adjuster-mac/commit/6449803b057ed6ea8a5ce737f176972e1e5305f0))
* self-calibrating anti-duck with safety servo ([0f46f44](https://github.com/clement880101/audio-adjuster-mac/commit/0f46f44c998b031e14aeacdf14bae72c59bc150b))
* settings store, process registry, tap channel, coordinator ([075e0fc](https://github.com/clement880101/audio-adjuster-mac/commit/075e0fca5228542723eb564f1f9c97351c2cdfe4))
* switch between linked and independent volumes ([17fcf23](https://github.com/clement880101/audio-adjuster-mac/commit/17fcf23884d5cfa0b725e6d6926e1233a5bd8bee))


### Bug Fixes

* hide background agents; add a debug log ([08a437b](https://github.com/clement880101/audio-adjuster-mac/commit/08a437b772fb62492550b68560cfb119da3f8bb5))
* installer advised on quarantine it had not checked for ([612729f](https://github.com/clement880101/audio-adjuster-mac/commit/612729f70a10fd3e2e420d4ead29acff2add435b))
* list idle apps, verify audio path end to end ([7c4966a](https://github.com/clement880101/audio-adjuster-mac/commit/7c4966a7e010692796c24d5918ac6e63cc2933c4))
* list stopped updating while the popover was open ([a9b43e2](https://github.com/clement880101/audio-adjuster-mac/commit/a9b43e2bfd19cc761b998b8d7a49a21ed47b8671))
* make the call app adjustable, always duck-compensated ([3b67fec](https://github.com/clement880101/audio-adjuster-mac/commit/3b67fec5e48b88f1b49b951fd4f31e0b258e3a5a))
* menu bar item rendered no glyph at all ([00498da](https://github.com/clement880101/audio-adjuster-mac/commit/00498daba5f1157af7e0f3e5c099d31264aa2845))
* never tap the call app; measure the duck ([3803fb0](https://github.com/clement880101/audio-adjuster-mac/commit/3803fb0dd1c3a4c28012f3dfea2b762f13b08ca6))
* one bar per app, not one per process ([82690a8](https://github.com/clement880101/audio-adjuster-mac/commit/82690a8003d3535e8d31c33da2bef41743f7c089))
* rows rendered blank - GeometryReader was driving row layout ([14609f6](https://github.com/clement880101/audio-adjuster-mac/commit/14609f650face327164f12e504c45369d7f3e21b))
* stamp the release tag into the bundle version ([c828970](https://github.com/clement880101/audio-adjuster-mac/commit/c828970eeb5203192ca5330bfbd2d95c3b449fc0))
* stop the debug log growing without bound; name call audio ([0829538](https://github.com/clement880101/audio-adjuster-mac/commit/0829538b28b7b67cfed78656d6ee12068c06fb9c))
