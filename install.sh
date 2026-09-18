#!/bin/sh
# Installs the latest Audio Adjuster release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/clement880101/audio-adjuster-mac/main/install.sh | sh
#
# Downloads the release asset, checks it, and installs it. It will tell you exactly what
# it is about to do with Gatekeeper and ask first.

set -eu

REPO="clement880101/audio-adjuster-mac"
APP="AudioAdjuster.app"
DEST="/Applications"
ASSET="AudioAdjuster-macos.zip"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- macOS version -----------------------------------------------------------------
# Core Audio process taps are macOS 14.2+. Without them the app has no mechanism at all.
os=$(sw_vers -productVersion 2>/dev/null) || die "this installer is for macOS"
major=${os%%.*}
rest=${os#*.}
minor=${rest%%.*}
[ "$minor" = "$rest" ] && minor=0
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "$minor" -lt 2 ]; }; then
    die "macOS 14.2 or later required (found $os)"
fi

# --- download ----------------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Finding the latest release..."
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -o "https://github.com/$REPO/releases/download/[^\"]*/$ASSET" \
      | head -1)
[ -n "$url" ] || die "no published release yet — build from source instead (see the README)"

say "Downloading $url"
curl -fsSL "$url" -o "$tmp/$ASSET" || die "download failed"

say "Unpacking..."
ditto -x -k "$tmp/$ASSET" "$tmp/unpacked" || die "the archive could not be expanded"
[ -d "$tmp/unpacked/$APP" ] || die "the archive did not contain $APP"

# --- install -----------------------------------------------------------------------
if [ -d "$DEST/$APP" ]; then
    say "Replacing the existing $DEST/$APP"
    pkill -f "$APP/Contents/MacOS" 2>/dev/null || true
    rm -rf "$DEST/$APP"
fi
ditto "$tmp/unpacked/$APP" "$DEST/$APP" || die "could not write to $DEST"
say "Installed $DEST/$APP"

# --- Gatekeeper --------------------------------------------------------------------
# The build is ad-hoc signed rather than notarized, because the project has no Apple
# Developer ID. macOS therefore refuses to open it normally. Removing the quarantine
# attribute is the documented way through that, but it is a real security decision and
# is not made silently here.
if [ -t 0 ] && [ -t 1 ]; then
    cat <<'EXPLAIN'

This build is ad-hoc signed, not notarized — the project has no Apple Developer ID,
so macOS cannot verify who built it and will refuse to open it normally.

Two ways forward:
  1. Leave it as is, and open the app the first time with right-click > Open,
     which lets you read macOS's warning and decide for yourself.
  2. Remove the quarantine flag now, which skips that prompt.

Only choose 2 if you trust where this came from.
EXPLAIN
    printf 'Remove the quarantine flag? [y/N] '
    read -r answer </dev/tty || answer=n
    case "$answer" in
        [Yy]*)
            xattr -d -r com.apple.quarantine "$DEST/$APP" 2>/dev/null || true
            say "Quarantine flag removed."
            ;;
        *)
            say "Left in place. Open it the first time with right-click > Open."
            ;;
    esac
else
    # Piped from curl, so there is no terminal to ask at. Never strip quarantine silently.
    say ""
    say "This build is ad-hoc signed, not notarized. Open it the first time with"
    say "right-click > Open so you can read macOS's warning and decide."
fi

say ""
say "Launch it with:  open -a $APP"
say "On first use it will ask for audio-recording permission. Process taps are gated"
say "behind it, and without it a tap returns silence rather than an error."
