PROJECT := spaces-renamer.xcodeproj
DERIVED_DATA := .build/DerivedData
XCODEBUILD := xcodebuild -project $(PROJECT) -configuration Release -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO
# SwiftPM-assembled app.
APP := .build/SpacesRenamer.app
MANPAGE := .build/man/sr.1
# Resolved once, at parse time. The build regenerates tracked files (the
# injection payload), so a lazily expanded `git describe` would read "-dirty"
# in a tagged release build. A command line or environment VERSION still wins.
# The leading "v" is dropped: the version lands in CFBundleShortVersionString
# and in the DMG name, where the tag is used without it.
ifndef VERSION
VERSION := $(patsubst v%,%,$(shell git describe --tags --always --dirty 2>/dev/null || echo 1.0.1))
endif
BUILD ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
SPM_DIR := SpacesRenamer
# The app binary comes from one xcodebuild pass over the SwiftPM package.
# SwiftPM's own multi-architecture build (swift build --arch arm64 --arch
# x86_64) fails on the CI runner's toolchain with a duplicate-output-file
# error; xcodebuild builds the same package in a single pass.
APP_BINARY := $(DERIVED_DATA)/Build/Products/Release/SpacesRenamer

.PHONY: app app-tahoe app-gg plugin bundle package-injection mip universal dmg background man verify inject clean test

app: bundle man
	# Build the Swift binary for the architectures the app ships (arm64 and
	# x86_64) in one xcodebuild pass; the bundle below is assembled by hand.
	cd "$(SPM_DIR)" && xcodebuild -scheme SpacesRenamer -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$(CURDIR)/$(DERIVED_DATA)" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
	# Assemble the app bundle by hand; SwiftPM emits a bare executable.
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(APP_BINARY)" "$(APP)/Contents/MacOS/SpacesRenamer"
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
	$(XCODEBUILD) -scheme spaces-renamer 'ARCHS=arm64e x86_64' 'SPACES_RENAMER_BUILD_NUMBER=$(BUILD)' build

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

# Rebuild the private MIP runtime from the vendored source. It is committed
# prebuilt, so this is not part of the default build; see injection/mip/README.md.
mip:
	@command -v gobjcopy >/dev/null 2>&1 || { \
		echo "error: gobjcopy not found; the MIP runtime needs GNU binutils" >&2; \
		echo "       brew install binutils" >&2; \
		echo "       export PATH=\"$$(brew --prefix binutils)/bin:$$PATH\"" >&2; \
		exit 1; }
	@echo "Rebuild command (injection/mip/README.md):"
	@echo '  brew install binutils'
	@echo '  export PATH="$$(brew --prefix binutils)/bin:$$PATH"'
	@echo '  make -C third_party/mip/MIP MIP_ROOT=/Library/SpacesRenamer/mip MIP_SERVICE_NAME=com.wiggly-sheets.spaces-renamer.injectd'
	$(MAKE) -C third_party/mip/MIP BUILD_DIR="$(CURDIR)/.build/mip" \
		MIP_ROOT=/Library/SpacesRenamer/mip \
		MIP_SERVICE_NAME=com.wiggly-sheets.spaces-renamer.injectd
	cp .build/mip/injectd .build/mip/loader.dylib .build/mip/lsdinjector.dylib \
		.build/mip/inject injection/mip/
	# The templates keep the @MIP_ROOT@ and @MIP_SERVICE_NAME@ placeholders: the launcher
	# substitutes them when it installs the runtime.
	cp third_party/mip/MIP/spacesrenamer.injectd.plist \
		third_party/mip/MIP/spacesrenamer.lsdinjector.plist injection/mip/

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
	# "lipo: -verify_arch requires exactly one input file" on this machine.
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
	# The private MIP runtime travels with the app.
	test -x "$(APP)/Contents/Resources/mip/injectd"
	test -f "$(APP)/Contents/Resources/mip/spacesrenamer.injectd.plist"
	test -f "$(APP)/Contents/Resources/man/man1/sr.1"
	test -f "$(APP)/Contents/_CodeSignature/CodeResources"
	codesign --verify --deep --strict --all-architectures "$(APP)"
	# The legacy run.sh/dylinject layout must no longer be embedded.
	test ! -e "$(APP)/Contents/Resources/Injection"
	# The narrow MIP path must be preferred when a MIP runtime is available.
	grep -Fq '(runtimeEmbedded || systemMIPAvailable) ? .mip : .dyld' "SpacesRenamer/Injector.swift"

test:
	./scripts/tests/test_release_notes.sh
	./scripts/tests/test_bump_cask.sh
	./scripts/tests/test_make_dmg.sh
	./scripts/tests/test_embed_injection.sh
	./scripts/tests/test_injector_runtime.sh
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