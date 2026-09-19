# A Command Line Tools install ships swift-testing outside the default search paths, so
# tests there need these flags spelled out. A full Xcode install supplies them itself, and
# passing the CLT paths would then point at frameworks that are not present — so they are
# added only when that CLT layout actually exists.
CLT  := /Library/Developer/CommandLineTools
FW   := $(CLT)/Library/Developer/Frameworks
LIB  := $(CLT)/Library/Developer/usr/lib
TESTFLAGS := $(if $(wildcard $(FW)/Testing.framework),\
             -Xswiftc -F -Xswiftc $(FW) \
             -Xlinker -F -Xlinker $(FW) \
             -Xlinker -rpath -Xlinker $(FW) \
             -Xlinker -rpath -Xlinker $(LIB),)

APP     := AudioAdjuster
BUNDLE  := build/$(APP).app
CONFIG  := release

## Version stamped into the bundle. The release workflow passes the tag, so a published
## build cannot disagree with the release it came from — it did once, silently.
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

.PHONY: test build app clean run probe icon

test:
	swift test $(TESTFLAGS)

build:
	swift build -c $(CONFIG)

## The icon is drawn rather than converted from an SVG: no rasteriser ships with macOS,
## and requiring one from Homebrew would put a dependency in front of `make app` that the
## rest of this build does not have.
ICONSET := build/$(APP).iconset
ICNS    := build/$(APP).icns
icon: build
	rm -rf $(ICONSET)
	.build/$(CONFIG)/BrandMarkRender $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)

## Assembles a real .app bundle. SwiftPM only produces a bare executable, so the bundle
## layout, Info.plist and signature are put together by hand here.
app: build icon
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp .build/$(CONFIG)/AudioAdjusterApp $(BUNDLE)/Contents/MacOS/$(APP)
	cp $(ICNS) $(BUNDLE)/Contents/Resources/$(APP).icns
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(BUNDLE)/Contents/Info.plist
	# Ad-hoc signature: no Developer ID is available, so macOS will re-prompt for the
	# audio-capture permission whenever the code hash changes.
	codesign --force --sign - \
		--entitlements Resources/AudioAdjuster.entitlements \
		--options runtime $(BUNDLE)
	@echo "built $(BUNDLE)"

run: app
	open $(BUNDLE)

## Zipped bundle for a release, alongside the checksum an installer verifies.
DIST := build/AudioAdjuster-macos.zip
dist: app
	rm -f $(DIST)
	ditto -c -k --keepParent $(BUNDLE) $(DIST)
	shasum -a 256 $(DIST) | tee $(DIST).sha256
	@echo "built $(DIST)"

probe: build
	@echo "run: .build/$(CONFIG)/AudioAdjusterProbe --list"

clean:
	rm -rf .build build

## The probe needs a real bundle identity too: Core Audio taps silently return zeros for a
## process that has no Info.plist for macOS to attach an audio-capture grant to.
PROBE_BUNDLE := build/AudioAdjusterProbe.app
probe-app: build
	rm -rf $(PROBE_BUNDLE)
	mkdir -p $(PROBE_BUNDLE)/Contents/MacOS
	cp .build/$(CONFIG)/AudioAdjusterProbe $(PROBE_BUNDLE)/Contents/MacOS/AudioAdjusterProbe
	sed -e 's|<string>AudioAdjuster</string>|<string>AudioAdjusterProbe</string>|' \
	    -e 's|com.audioadjuster.AudioAdjuster|com.audioadjuster.AudioAdjusterProbe|' \
	    Resources/Info.plist > $(PROBE_BUNDLE)/Contents/Info.plist
	codesign --force --sign - \
		--entitlements Resources/AudioAdjuster.entitlements \
		--options runtime $(PROBE_BUNDLE)
	@echo "built $(PROBE_BUNDLE)"
