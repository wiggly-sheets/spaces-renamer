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

universal: app
	$(MAKE) verify

dmg: app
	./packaging/make-dmg.sh $(VERSION)

background:
	swift packaging/render-background.swift packaging/background.png

man:
	@command -v scdoc >/dev/null || { echo "error: scdoc not found (brew install scdoc)" >&2; exit 1; }
	mkdir -p "$(dir $(MANPAGE))"
	scdoc < docs/sr.1.scd > "$(MANPAGE)"

verify:
	lipo "$(APP)/Contents/MacOS/SpacesRenamer" -verify_arch arm64 x86_64
	lipo "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.bundle/Contents/MacOS/spaces-renamer" -verify_arch arm64e x86_64
	lipo injection/lib/spaces-renamer.dylib -verify_arch arm64e
	# Embedded injection stack presence + architecture checks.
	test -x "$(APP_INJECTION)/run.sh"
	test -x "$(APP_INJECTION)/lib/dylinject"
	lipo "$(APP_INJECTION)/lib/dylinject" -verify_arch arm64e
	lipo "$(APP_INJECTION)/lib/spaces-renamer.dylib" -verify_arch arm64e
	cmp -s injection/lib/spaces-renamer.dylib "$(APP_INJECTION)/lib/spaces-renamer.dylib"
	test -f "$(APP)/Contents/Resources/man/man1/sr.1"
	test -f "$(APP)/Contents/_CodeSignature/CodeResources"
	codesign --verify --deep --strict --all-architectures "$(APP)"

test:
	./scripts/tests/test_release_notes.sh
	./scripts/tests/test_bump_cask.sh
	./scripts/tests/test_make_dmg.sh
	./scripts/tests/test_embed_injection.sh
	./scripts/tests/test_manpage.sh
	./scripts/tests/test_settings_contracts.sh
	./scripts/tests/test_cli.sh
	./scripts/tests/test_make_verify.sh
	./scripts/tests/test_dock_hook_safety.sh
	./scripts/tests/test_injection_lifecycle.sh
	./scripts/tests/test_app_policies.sh
	./scripts/tests/test_yabai_client.sh
	./scripts/tests/test_preference_config_policies.sh
	./scripts/tests/test_replacing_file_watcher.sh
	./scripts/tests/test_injection_command.sh

clean:
	xcodebuild -project $(PROJECT) -scheme SpacesRenamer clean
	xcodebuild -project $(PROJECT) -scheme spaces-renamer clean
