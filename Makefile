PROJECT := spaces-renamer.xcodeproj
DERIVED_DATA := .build/DerivedData
XCODEBUILD := xcodebuild -project $(PROJECT) -configuration Release -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO
# SwiftPM-assembled app.
APP := .build/SpacesRenamer.app
MANPAGE := .build/man/sr.1
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo 1.0.1)
BUILD ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
SWIFT_BUILD := swift build --package-path SpacesRenamer -c release --arch arm64 --arch x86_64
SPM_BIN := $(shell $(SWIFT_BUILD) --show-bin-path)/SpacesRenamer

.PHONY: app app-tahoe app-gg plugin bundle package-injection universal dmg background man verify inject clean test

app: bundle man
	$(SWIFT_BUILD)
	# Assemble the app bundle by hand; SwiftPM emits a bare executable.
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(SPM_BIN)" "$(APP)/Contents/MacOS/SpacesRenamer"
	# Substitute the Xcode build-variable placeholders (the hand-assembled
	# bundle has no Xcode build to expand them; an unresolved identifier also
	# breaks codesign).
	sed -e 's/\$$(MARKETING_VERSION)/$(VERSION)/' \
	    -e 's/\$$(MACOSX_DEPLOYMENT_TARGET)/14.0/' \
	    -e 's/\$$(PRODUCT_BUNDLE_IDENTIFIER)/com.wiggly-sheets.SpacesRenamer/' \
	    -e 's/\$$(EXECUTABLE_NAME)/SpacesRenamer/' \
	    -e 's/\$$(PRODUCT_NAME)/SpacesRenamer/' \
	    -e 's/\$$(DEVELOPMENT_LANGUAGE)/English/' \
	    SpacesRenamer/Info.plist > "$(APP)/Contents/Info.plist"
	# The asset catalog ships an AppIcon (actool emits Assets.car + AppIcon.icns
	# into Resources); record it so macOS picks the icon up.
	xcrun actool SpacesRenamer/Assets.xcassets --compile "$(APP)/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist .build/AssetsPartial.plist
	/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' -c 'Add :CFBundleIconName string AppIcon' "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	# Ad-hoc signature before embedding; embed-injection.sh re-signs at the end.
	codesign --force --sign - --entitlements SpacesRenamer/SpacesRenamer.entitlements "$(APP)"
	# Bundle CLI tool into app resources.
	cp cli/sr "$(APP)/Contents/Resources/sr"
	chmod 0755 "$(APP)/Contents/Resources/sr"
	mkdir -p "$(APP)/Contents/Resources/man/man1"
	cp "$(MANPAGE)" "$(APP)/Contents/Resources/man/man1/sr.1"
	# Bundle injection stack into app resources.
	./scripts/embed-injection.sh "$(APP)"

# Universal build for macOS 26 (Tahoe) — runs on both Intel and Apple Silicon.
app-tahoe: bundle man
	swift build --package-path SpacesRenamer -c release --arch arm64 --arch x86_64
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(shell swift build --package-path SpacesRenamer -c release --arch arm64 --arch x86_64 --show-bin-path)/SpacesRenamer" "$(APP)/Contents/MacOS/SpacesRenamer"
	sed -e 's/\$$(MARKETING_VERSION)/$(VERSION)/' \
	    -e 's/\$$(MACOSX_DEPLOYMENT_TARGET)/14.0/' \
	    -e 's/\$$(PRODUCT_BUNDLE_IDENTIFIER)/com.wiggly-sheets.SpacesRenamer/' \
	    -e 's/\$$(EXECUTABLE_NAME)/SpacesRenamer/' \
	    -e 's/\$$(PRODUCT_NAME)/SpacesRenamer/' \
	    -e 's/\$$(DEVELOPMENT_LANGUAGE)/English/' \
	    SpacesRenamer/Info.plist > "$(APP)/Contents/Info.plist"
	xcrun actool SpacesRenamer/Assets.xcassets --compile "$(APP)/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist .build/AssetsPartial.plist
	/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' -c 'Add :CFBundleIconName string AppIcon' "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	codesign --force --sign - --entitlements SpacesRenamer/SpacesRenamer.entitlements "$(APP)"
	cp cli/sr "$(APP)/Contents/Resources/sr"
	chmod 0755 "$(APP)/Contents/Resources/sr"
	mkdir -p "$(APP)/Contents/Resources/man/man1"
	cp "$(MANPAGE)" "$(APP)/Contents/Resources/man/man1/sr.1"
	./scripts/embed-injection.sh "$(APP)"

# arm64-only build for macOS 27+ (Golden Gate) — Apple Silicon only.
app-gg: bundle man
	swift build --package-path SpacesRenamer -c release --arch arm64
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(shell swift build --package-path SpacesRenamer -c release --arch arm64 --show-bin-path)/SpacesRenamer" "$(APP)/Contents/MacOS/SpacesRenamer"
	sed -e 's/\$$(MARKETING_VERSION)/$(VERSION)/' \
	    -e 's/\$$(MACOSX_DEPLOYMENT_TARGET)/27.0/' \
	    -e 's/\$$(PRODUCT_BUNDLE_IDENTIFIER)/com.wiggly-sheets.SpacesRenamer/' \
	    -e 's/\$$(EXECUTABLE_NAME)/SpacesRenamer/' \
	    -e 's/\$$(PRODUCT_NAME)/SpacesRenamer/' \
	    -e 's/\$$(DEVELOPMENT_LANGUAGE)/English/' \
	    SpacesRenamer/Info.plist > "$(APP)/Contents/Info.plist"
	xcrun actool SpacesRenamer/Assets.xcassets --compile "$(APP)/Contents/Resources" --platform macosx --minimum-deployment-target 27.0 --app-icon AppIcon --output-partial-info-plist .build/AssetsPartial.plist
	/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' -c 'Add :CFBundleIconName string AppIcon' "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	codesign --force --sign - --entitlements SpacesRenamer/SpacesRenamer.entitlements "$(APP)"
	cp cli/sr "$(APP)/Contents/Resources/sr"
	chmod 0755 "$(APP)/Contents/Resources/sr"
	mkdir -p "$(APP)/Contents/Resources/man/man1"
	cp "$(MANPAGE)" "$(APP)/Contents/Resources/man/man1/sr.1"
	./scripts/embed-injection.sh "$(APP)"

plugin:
	$(XCODEBUILD) -scheme spaces-renamer 'ARCHS=arm64e x86_64' build

package-injection: plugin
	lipo "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.dylib" -thin arm64e -output injection/lib/spaces-renamer.dylib
	# lipo -thin keeps only the linker signature. The kernel's code-signing monitor
	# rejects that for DYLD-injected libraries on arm64e (the host is SIGKILLed with
	# "Code Signature Invalid" on relaunch), so re-sign the payload ad-hoc.
	codesign --force --sign - injection/lib/spaces-renamer.dylib

# Assemble the MIP bundle consumed by injection/injector.sh `mip on`.
bundle: package-injection
	rm -rf build/SpacesRenamer.mip.bundle
	mkdir -p build/SpacesRenamer.mip.bundle/Contents/MacOS
	sed -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD)/' packaging/mip/Info.plist > build/SpacesRenamer.mip.bundle/Contents/Info.plist
	cp injection/lib/spaces-renamer.dylib build/SpacesRenamer.mip.bundle/Contents/MacOS/SpacesRenamer

# Manual DYLD activation for testing: copies the payload to ~/Library/Application
# Support/SpacesRenamer and installs the LaunchAgent.
inject:
	./injection/injector.sh dyld on "$(abspath injection/lib/spaces-renamer.dylib)"

universal: app
	$(MAKE) verify

dmg: app
	./packaging/make-dmg.sh $(VERSION) $(APP)

background:
	swift packaging/render-background.swift packaging/background.png

man:
	@command -v scdoc >/dev/null || { echo "error: scdoc not found (brew install scdoc)" >&2; exit 1; }
	mkdir -p "$(dir $(MANPAGE))"
	scdoc < docs/sr.1.scd > "$(MANPAGE)"

verify:
	# One -verify_arch per invocation: the multi-arch form trips
	# `lipo: -verify_arch requires exactly one input file` on this machine.
	lipo "$(APP)/Contents/MacOS/SpacesRenamer" -verify_arch arm64
	lipo "$(APP)/Contents/MacOS/SpacesRenamer" -verify_arch x86_64
	lipo "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.dylib" -verify_arch arm64e
	lipo "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.dylib" -verify_arch x86_64
	lipo injection/lib/spaces-renamer.dylib -verify_arch arm64e
	# Embedded DYLD injector script + MIP payload presence checks.
	test -x "$(APP)/Contents/Resources/injector.sh"
	lipo "$(APP)/Contents/PlugIns/spaces-renamer.dylib" -verify_arch arm64e
	cmp -s injection/lib/spaces-renamer.dylib "$(APP)/Contents/PlugIns/spaces-renamer.dylib"
	test -d "$(APP)/Contents/Resources/SpacesRenamer.mip.bundle"
	grep -q WindowManager "$(APP)/Contents/Resources/SpacesRenamer.mip.bundle/Contents/Info.plist"
	grep -q Dock "$(APP)/Contents/Resources/SpacesRenamer.mip.bundle/Contents/Info.plist"
	test -f "$(APP)/Contents/Resources/man/man1/sr.1"
	test -f "$(APP)/Contents/_CodeSignature/CodeResources"
	codesign --verify --deep --strict --all-architectures "$(APP)"
	# The legacy run.sh/dylinject layout must no longer be embedded.
	test ! -e "$(APP)/Contents/Resources/Injection"

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
	./scripts/tests/test_app_policies.sh
	./scripts/tests/test_yabai_client.sh
	./scripts/tests/test_preference_config_policies.sh
	./scripts/tests/test_replacing_file_watcher.sh
	swift test --package-path SpacesRenamer

clean:
	xcodebuild -project $(PROJECT) -scheme spaces-renamer clean
	swift package --package-path SpacesRenamer clean
	rm -rf "$(APP)"