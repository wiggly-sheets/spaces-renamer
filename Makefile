PROJECT := spaces-renamer.xcodeproj
DERIVED_DATA := .build/DerivedData
XCODEBUILD := xcodebuild -project $(PROJECT) -configuration Release -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO
APP := $(DERIVED_DATA)/Build/Products/Release/SpacesRenamer.app
VERSION ?=

.PHONY: app plugin package-injection universal dmg background verify clean test

app:
	$(XCODEBUILD) -scheme SpacesRenamer 'ARCHS=arm64 x86_64' build
	# Bundle CLI tool into app resources.
	mkdir -p "$(APP)/Contents/Resources"
	cp cli/sr "$(APP)/Contents/Resources/sr"
	chmod 0755 "$(APP)/Contents/Resources/sr"

plugin:
	$(XCODEBUILD) -scheme spaces-renamer 'ARCHS=arm64e x86_64' build

package-injection: plugin
	lipo "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.bundle/Contents/MacOS/spaces-renamer" -thin arm64e -output injection/lib/spaces-renamer.dylib

universal: app package-injection verify

dmg: app
	./packaging/make-dmg.sh $(VERSION)

background:
	swift packaging/render-background.swift packaging/background.png

verify:
	lipo -info "$(APP)/Contents/MacOS/SpacesRenamer"
	lipo -info "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.bundle/Contents/MacOS/spaces-renamer"
	lipo -info injection/lib/spaces-renamer.dylib

test:
	./scripts/tests/test_release_notes.sh
	./scripts/tests/test_bump_cask.sh
	./scripts/tests/test_make_dmg.sh

clean:
	xcodebuild -project $(PROJECT) -scheme SpacesRenamer clean
	xcodebuild -project $(PROJECT) -scheme spaces-renamer clean
