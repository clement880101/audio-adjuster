# Command Line Tools ship swift-testing outside the default search paths, so tests need
# these explicitly. (Xcode would supply them automatically.)
CLT  := /Library/Developer/CommandLineTools
FW   := $(CLT)/Library/Developer/Frameworks
LIB  := $(CLT)/Library/Developer/usr/lib
TESTFLAGS := -Xswiftc -F -Xswiftc $(FW) \
             -Xlinker -F -Xlinker $(FW) \
             -Xlinker -rpath -Xlinker $(FW) \
             -Xlinker -rpath -Xlinker $(LIB)

APP     := AudioAdjuster
BUNDLE  := build/$(APP).app
CONFIG  := release

.PHONY: test build app clean run probe

test:
	swift test $(TESTFLAGS)

build:
	swift build -c $(CONFIG)

## Assembles a real .app bundle. SwiftPM only produces a bare executable, so the bundle
## layout, Info.plist and signature are put together by hand here.
app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp .build/$(CONFIG)/AudioAdjusterApp $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	# Ad-hoc signature: no Developer ID is available, so macOS will re-prompt for the
	# audio-capture permission whenever the code hash changes.
	codesign --force --sign - \
		--entitlements Resources/AudioAdjuster.entitlements \
		--options runtime $(BUNDLE)
	@echo "built $(BUNDLE)"

run: app
	open $(BUNDLE)

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
