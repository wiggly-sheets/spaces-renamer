PROJECT := spaces-renamer.xcodeproj
DERIVED_DATA := .build/DerivedData
XCODEBUILD := xcodebuild -project $(PROJECT) -configuration Release -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO
APP := $(DERIVED_DATA)/Build/Products/Release/SpacesRenamer.app
APP_INJECTION := $(APP)/Contents/Resources/Injection
MANPAGE := .build/man/sr.1
VERSION ?=

.PHONY: app plugin package-injection universal dmg background man verify clean test

app: package-injection man
	$(XCODEBUILD) -scheme SpacesRenamer 'ARCHS=arm64 x86_64' build
	# Bundle CLI tool into app resources.
	mkdir -p "$(APP)/Contents/Resources"
	cp cli/sr "$(APP)/Contents/Resources/sr"
	chmod 0755 "$(APP)/Contents/Resources/sr"
	mkdir -p "$(APP)/Contents/Resources/man/man1"
	cp "$(MANPAGE)" "$(APP)/Contents/Resources/man/man1/sr.1"
	# Bundle injection stack into app resources.
	./scripts/embed-injection.sh "$(APP)" injection

plugin:
	$(XCODEBUILD) -scheme spaces-renamer 'ARCHS=arm64e x86_64' build

package-injection: plugin
	lipo "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.bundle/Contents/MacOS/spaces-renamer" -thin arm64e -output injection/lib/spaces-renamer.dylib

universal: app package-injection verify

dmg: app
	./packaging/make-dmg.sh $(VERSION)

background:
	swift packaging/render-background.swift packaging/background.png

man:
	@command -v scdoc >/dev/null || { echo "error: scdoc not found (brew install scdoc)" >&2; exit 1; }
	mkdir -p "$(dir $(MANPAGE))"
	scdoc < docs/sr.1.scd > "$(MANPAGE)"

verify:
	lipo -info "$(APP)/Contents/MacOS/SpacesRenamer"
	lipo -info "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.bundle/Contents/MacOS/spaces-renamer"
	lipo -info injection/lib/spaces-renamer.dylib
	# Embedded injection stack presence + architecture checks.
	test -x "$(APP_INJECTION)/run.sh"
	test -x "$(APP_INJECTION)/lib/dylinject"
	lipo -info "$(APP_INJECTION)/lib/spaces-renamer.dylib"
	test -f "$(APP)/Contents/Resources/man/man1/sr.1"

test:
	./scripts/tests/test_release_notes.sh
	./scripts/tests/test_bump_cask.sh
	./scripts/tests/test_make_dmg.sh
	./scripts/tests/test_embed_injection.sh
	./scripts/tests/test_manpage.sh
	./scripts/tests/test_settings_contracts.sh

clean:
	xcodebuild -project $(PROJECT) -scheme SpacesRenamer clean
	xcodebuild -project $(PROJECT) -scheme spaces-renamer clean
