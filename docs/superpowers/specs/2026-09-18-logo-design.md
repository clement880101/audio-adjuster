# Logo — Design

Date: 2026-09-18
Status: agreed, not yet implemented

## Problem

The app has no icon. `Resources/Info.plist` names no `CFBundleIconFile`, so the bundle
carries none and macOS falls back to the generic blank-document icon everywhere the app
is shown by name: Finder, Spotlight, Force Quit, notification alerts, and — the one that
costs us something — the audio-recording permission prompt, where an unsigned app with a
blank icon asking to record audio is exactly the shape of something you decline.

The site has no mark either. The masthead is the bare word "Audio Adjuster" and the
favicon is a 🎚️ emoji in an SVG data URI.

## The mark

Three stacked level bars: a dim full-width track with an amber fill, one row per app.
It is the app's own popover reduced to its smallest honest form, and it already appears
on `site/og.png`, so it is consistent with what is published today.

Geometry, in a 100×100 box:

| | x | y | width | height | rx |
|---|---|---|---|---|---|
| track 1 | 8 | 16 | 84 | 16 | 8 |
| track 2 | 8 | 42 | 84 | 16 | 8 |
| track 3 | 8 | 68 | 84 | 16 | 8 |
| fill 1 | 8 | 16 | 52 | 16 | 8 |
| fill 2 | 8 | 42 | 80 | 16 | 8 |
| fill 3 | 8 | 68 | 32 | 16 | 8 |

Fills are 62%, 95% and 38% of the track. The middle bar is the longest, matching the
levels already drawn on the OG card. The shortest fill (32) is wider than the bar is tall
(16), so every fill keeps a proper rounded cap rather than collapsing to a circle.

Colours are the site's: track `#22262a`, fill `#f2a33c` (`--accent`).

### Two forms

Three bars at 16px render as roughly 2.5px each. Tracks and fills become indistinguishable
at that size, so the mark has two forms:

- **Full form** — tracks and fills. Used at 64px and above: app icon rungs 64 and up, site
  masthead.
- **Reduced form** — fills only, no tracks, bars thickened to fill the space the tracks
  leave behind. Used below 64px: menu bar glyph, favicon, app icon rungs 16 and 32.

Reduced-form geometry in the same 100×100 box: bars at `x=8`, `h=20`, `rx=10`, rows at
`y=12`, `y=40`, `y=68`; widths 52, 80, 32 unchanged. Dropping the tracks frees the
vertical space that lets the bars grow from 16 to 20.

Both forms keep the same three widths and the same silhouette, so they read as one mark.

## Where the geometry lives

The numbers exist twice: once in Swift (`Sources/BrandMark/BrandMark.swift`), once as
inline SVG in `site/index.html`. This duplication is deliberate. The mark is six
rectangles; a build step that generated the site's HTML from the Swift definition would
be more machinery than the duplication costs, and the site must stay dependency-free
static HTML. Both copies carry a comment naming the other, so a change to one is a
prompt to change the other.

## App side

### `BrandMark` — new library target

One file. Public API:

```swift
public enum BrandMarkForm { case full, reduced }

public enum BrandMark {
    /// Draws the mark, scaled to fill `rect`, in the given form.
    /// `color` paints the fills; `trackColor` paints the tracks and is ignored
    /// by the reduced form.
    public static func draw(in context: CGContext, rect: CGRect,
                            form: BrandMarkForm,
                            color: CGColor, trackColor: CGColor)

    /// Draws the mark on the macOS application-icon canvas: an 824×824 squircle
    /// inset in a 1024-square, scaled to `size`.
    public static func drawAppIcon(in context: CGContext, size: CGFloat)
}
```

It depends on CoreGraphics only — not on `AudioAdjusterKit`, which is audio logic and
has no business knowing about drawing.

### Menu bar glyph

`AudioAdjusterApp` builds an 18×18pt `NSImage` from the reduced form, sets
`isTemplate = true`, and switches from

```swift
MenuBarExtra("Audio Adjuster", systemImage: "slider.horizontal.3") { ... }
```

to the `MenuBarExtra(_:content:label:)` form with `Image(nsImage:)`. A template image
means macOS handles the light menu bar, the dark menu bar, and the highlighted state
itself — the drawing code picks no colours.

### `BrandMarkRender` — new executable target

Takes an output directory and writes the ten-rung iconset:

```
icon_16x16.png      16     reduced
icon_16x16@2x.png   32     reduced
icon_32x32.png      32     reduced
icon_32x32@2x.png   64     full
icon_128x128.png    128    full
icon_128x128@2x.png 256    full
icon_256x256.png    256    full
icon_256x256@2x.png 512    full
icon_512x512.png    512    full
icon_512x512@2x.png 1024   full
```

Form is chosen by pixel size, not by rung name, so the two files that share a pixel size
are byte-identical.

The icon canvas is an 824×824 squircle (corner radius 185.4 at 1024, scaled
proportionally) centred in the square, filled with a vertical `#1a1d20 → #0f1113`
gradient, with the mark centred at 600/1024 of the canvas width.

### Build

`make icon` runs `BrandMarkRender` into `build/AudioAdjuster.iconset` and pipes it
through `iconutil -c icns`. `make app` gains a dependency on `icon`, copies
`build/AudioAdjuster.icns` into `Contents/Resources/`, and `Resources/Info.plist` gains:

```xml
<key>CFBundleIconFile</key>
<string>AudioAdjuster</string>
```

`make clean` already removes `build/`, and `.gitignore` already lists `build/`, so the
generated iconset and `.icns` stay out of the repository without any further change.

**Why generate rather than commit a `.icns`:** no SVG rasteriser is installed on this
machine (`rsvg-convert`, Inkscape, ImageMagick and `cairosvg` are all absent), and adding
one would put a Homebrew dependency in front of `make app` for a repo that today needs
nothing but a Swift toolchain. Drawing the icon in Swift keeps the build self-contained
and the icon regenerable from source, at the cost of one extra target.

## Site side

- **Masthead** — the full-form mark inline at 22px, to the left of "Audio Adjuster", with
  `fill: var(--accent)` on the fills and `var(--line)` on the tracks. The masthead is
  currently a bare `<span>`; it becomes a flex row with the SVG and the word.
- **Favicon** — the reduced form as an SVG data URI on the dark rounded tile, replacing
  the 🎚️ emoji. Keeping the tile means the favicon reads on both a light and a dark
  browser tab, which bare amber bars would not.
- **`og.png`** — a new `site/og.html` reproduces the existing card exactly, with the mark
  added beside the footer wordmark. It is screenshotted at 1200×630 to replace
  `site/og.png`. The card's fonts (Instrument Serif, IBM Plex Mono) are not installed on
  this machine, so a browser render is the only way to match the published typography —
  and it makes the card regenerable, which it currently is not. `og.html` is committed
  alongside the PNG as its source; it is excluded from `sitemap.xml` and gets
  `<meta name="robots" content="noindex">` so it is not indexed as a page.

The `og:image:alt` text already reads "a stack of level bars", so it needs no change.

## Testing

`BrandMark` is geometry, and geometry is worth a test only where it can silently go
wrong. Two tests in a new `BrandMarkTests` target:

1. **Bounds** — for both forms, at several sizes, every drawn rectangle falls inside the
   requested `rect`. Catches a scaling error that would clip the mark or bleed it past
   the canvas.
2. **Non-blank render** — rendering each form into a bitmap context produces a non-zero
   count of coloured pixels, and the reduced form at 16×16 produces at least three
   horizontal runs of coloured pixels separated by gaps. Catches the failure that matters
   at small sizes: bars merging into one block.

Existing `swift test` must stay green.

## Verification

- `swift test` passes, including the new target.
- `make app` produces a bundle whose icon renders correctly in Finder at icon, list and
  gallery sizes.
- The menu bar glyph is checked against both a light and a dark menu bar.
- `site/index.html` is checked in a browser at desktop and at 375px width; the masthead
  mark aligns with the wordmark and the nav at both.
- The regenerated `og.png` is 1200×630 and visually matches the previous card apart from
  the added mark.

## Out of scope

- A README header image.
- Any change to the popover UI inside the app.
- Replacing the wordmark's typography or the site's palette.

## What changed during implementation

- **Middle fill 80 → 70** (95% → 83% of the track). At 95% the track showed as a
  four-unit sliver past the end of the fill, which read as a rendering artefact rather
  than as a level. 83% leaves a visible remainder on every row.
- **`og.html` breaks its headline with `<br>`** rather than relying on a width that
  happens to wrap in the right place. Matching the old card's "Every app gets its own /
  volume." by tuning `width` meant the wrap point moved with every font-size nudge.
- **The masthead wordmark is hidden below 560px**, leaving the mark alone. The mark cost
  the masthead 31px, and at 375px the nav was already clipping "HOW" *before* this
  change; dropping the word buys back about 124px, so the narrow masthead now fits all
  four nav items where it previously did not. The word stays in the document, clipped
  rather than `display:none`, so screen readers still announce it.
- **The card's repo URL was stale.** The old `og.png` read
  `github.com/clement880101/audio-adjuster`; the repository is `audio-adjuster-mac`. The
  regenerated card corrects it.
- **Rendered with headless Chrome** rather than by hand-driving a browser. The exact
  command is in the comment at the top of `og.html`.
- **The pre-existing mobile overflow was left alone.** At 375px the hero `h1`
  (`clamp(3.2rem,8vw,5.6rem)`) is wider than the viewport and is clipped by
  `overflow-x:hidden`. This is on `main` today, it is not caused by the mark, and fixing
  it is a separate change.

## The menu bar glyph ships as a bundle resource, not a label view

The design said the app would build an 18pt `NSImage` and pass it to
`MenuBarExtra(content:label:)`. It is built the other way round — the glyph is written
into the bundle and named:

    MenuBarExtra("Audio Adjuster", image: "MenuBarGlyphTemplate") { ... }

`BrandMarkRender` writes `MenuBarGlyphTemplate.png` and `@2x` into `Contents/Resources/`
alongside the `.icns`. The `Template` suffix is load bearing: `NSImage(named:)` reads it
and sets `isTemplate`, which is what makes macOS invert the glyph for a light or dark
menu bar, so nothing in the app picks a colour.

This removed code rather than adding it. `MenuBarIcon.swift` is gone and
`AudioAdjusterApp` no longer depends on `BrandMark`, because the glyph is a build
artefact rather than something drawn at runtime — the same thing the `.icns` already was.

A note for anyone who finds the icon missing after a change here: it is worth ruling out
a full menu bar before suspecting the code. macOS silently drops status items when the
bar runs out of room, and from outside the process there is no easy way to tell that from
an item that was never created — `CGWindowListCopyWindowInfo` does not report status bar
windows even when one is visible, and screenshots are filtered to granted applications,
which a background agent is not.
