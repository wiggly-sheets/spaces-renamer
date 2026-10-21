# Spaces Renamer — build interface.
#
# `make` prints the list of targets. Every target is phony.

SHELL := /bin/bash

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
# The recipes read the version from the environment, so a version that holds a
# quote cannot break out of a command line.
export VERSION
BUILD ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
SPM_DIR := SpacesRenamer
# The vendored MIP build signs with the upstream identity name "CodeSign",
# which does not exist on a clean machine. Sign ad-hoc by default; pass
# SIGN_IDENTITY="Apple Development: ..." on the command line to override.
SIGN_IDENTITY ?= -
# GNU binutils' gobjcopy is keg-only: `brew install binutils` installs it in
# the keg, not on PATH. Resolve it once so `make mip` needs no PATH export.
# The lookup never breaks the parse: a missing tool is reported by the mip
# target, not by every other target.
BREW_BINUTILS_PREFIX := $(shell command -v brew >/dev/null 2>&1 && brew --prefix binutils 2>/dev/null)
GOBJCOPY ?= $(if $(wildcard $(BREW_BINUTILS_PREFIX)/bin/gobjcopy),$(BREW_BINUTILS_PREFIX)/bin/gobjcopy,gobjcopy)
# The app binary comes from one xcodebuild pass over the SwiftPM package.
# SwiftPM's own build path fails on the CI runner's toolchain with a
# duplicate-output-file error; xcodebuild builds the same package in a single
# pass. The product is Apple silicon only: the app ships arm64.
APP_BINARY := $(DERIVED_DATA)/Build/Products/Release/SpacesRenamer
APP_BUILD := cd "$(SPM_DIR)" && xcodebuild -scheme SpacesRenamer -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$(CURDIR)/$(DERIVED_DATA)" ARCHS='arm64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build

# The name of the disk image and of the checksum file next to it. The tap
# matches the assets by name, so these names never change.
DMG_NAME := SpacesRenamer-v$(VERSION).dmg

.PHONY: help build test app plugin bundle package-injection mip build-all dmg background man verify inject release-artifacts release clean

.DEFAULT_GOAL := help

## help — list every target

help:
	@printf '%s\n' \
		'Spaces Renamer — build targets.' \
		'' \
		'  help                 List every target (default).' \
		'  build                Build the SwiftPM package with xcodebuild.' \
		'  test                 Run the test suite.' \
		'  app                  Build the shipping bundle into .build/SpacesRenamer.app.' \
		'  dmg                  Build the disk image .build/DerivedData/SpacesRenamer-v<version>.dmg.' \
		'  release-artifacts    Build the DMG and write the checksum file the Homebrew tap reads.' \
		'  release VERSION=x.y.z  Build the artifacts, tag v<x.y.z> locally, print the push command.' \
		'  clean                Remove the build output.' \
		'' \
		'  build-all            Build the app and the Dock bundle, then verify the slices.' \
		'  plugin               Build the arm64e Dock bundle.' \
		'  package-injection    Refresh the tracked arm64e payload.' \
		'  bundle               Assemble the MIP bundle.' \
		'  verify               Verify the arm-only slices and the embedded payload.' \
		'  man                  Build the man page.' \
		'  background           Render the disk image background.' \
		'  mip                  Rebuild the private MIP runtime.' \
		'  inject               Activate the DYLD path by hand.' \
		'' \
		'Notes' \
		'  The product is Apple silicon only: the app is arm64 and the injected hook is' \
		'  arm64e, so there is no per-architecture target.' \
		'  The tag is the only source of the version. `make release VERSION=1.2.3` and the' \
		'  release workflow take the version from the command line and stamp it into the' \
		'  bundle. MARKETING_VERSION in spaces-renamer.xcodeproj is a build setting that' \
		'  the Makefile overrides; it is not a second source of truth.' \
		'  `make release` refuses a dirty working tree, a version whose tag already exists' \
		'  and a bundle that reports another version than the one asked for. It creates the' \
		'  annotated tag v<x.y.z> and prints the push command. It never pushes.' \
		'  The checksum file holds one line per asset: the digest, two spaces, the bare' \
		'  file name. The names of the assets never change, because the tap matches them.' \
		'  Signing stays ad-hoc: identity "-", no certificate, no notarization.' \
		'  create-dmg is required for the dmg targets: brew install create-dmg.'

## build — build the project

build:
	# SwiftPM's own build path fails on the CI runner's toolchain, so the
	# package is built by xcodebuild in one pass, like the app target does.
	$(APP_BUILD)

## test — test suite

test:
	./scripts/tests/test_release_notes.sh
	./scripts/tests/test_make_dmg.sh
	./scripts/tests/test_embed_injection.sh
	./scripts/tests/test_injector_runtime.sh
	./scripts/tests/test_manpage.sh
	./scripts/tests/test_settings_contracts.sh
	./scripts/tests/test_cli.sh
	./scripts/tests/test_make_verify.sh
	./scripts/tests/test_make_release.sh
	./scripts/tests/test_dock_hook_safety.sh
	./scripts/tests/test_app_policies.sh
	./scripts/tests/test_yabai_client.sh
	./scripts/tests/test_preference_config_policies.sh
	./scripts/tests/test_replacing_file_watcher.sh
	swift test --package-path SpacesRenamer

## app — the bundle the product ships

app: bundle man
	# Build the Swift binary for the architecture the app ships (arm64) in one
	# xcodebuild pass; the bundle below is assembled by hand.
	$(APP_BUILD)
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

plugin:
	$(XCODEBUILD) -scheme spaces-renamer 'ARCHS=arm64e' 'SPACES_RENAMER_BUILD_NUMBER=$(BUILD)' build

package-injection: plugin
	# The plugin builds arm64e only, so the built dylib is already the slice
	# we ship; lipo -thin would reject it as not being a fat file.
	cp "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.dylib" injection/lib/spaces-renamer.dylib
	# The linker signature alone is rejected for DYLD-injected libraries on
	# arm64e (the host is SIGKILLed with "Code Signature Invalid" on
	# relaunch), so re-sign the payload ad-hoc.
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
	@command -v "$(GOBJCOPY)" >/dev/null 2>&1 || { \
		echo "error: gobjcopy not found; the MIP runtime needs GNU binutils" >&2; \
		echo "       brew install binutils" >&2; \
		exit 1; }
	@echo "Rebuild command (injection/mip/README.md):"
	@echo '  brew install binutils'
	@echo '  make mip'
	@echo '  make -C third_party/mip/MIP MIP_ROOT=/Library/SpacesRenamer/mip MIP_SERVICE_NAME=com.wiggly-sheets.spaces-renamer.injectd BUILD_DIR="$(CURDIR)/.build/mip" SIGN_IDENTITY="$(SIGN_IDENTITY)" GOBJCOPY="$(GOBJCOPY)"'
	$(MAKE) -C third_party/mip/MIP MIP_ROOT=/Library/SpacesRenamer/mip \
		MIP_SERVICE_NAME=com.wiggly-sheets.spaces-renamer.injectd \
		BUILD_DIR="$(CURDIR)/.build/mip" \
		SIGN_IDENTITY="$(SIGN_IDENTITY)" \
		GOBJCOPY="$(GOBJCOPY)"
	# The vendored build makes the loader fat (arm64e plus an Intel slice for
	# Rosetta). Only arm64e hosts can load it, so ship the arm64e slice alone.
	lipo .build/mip/loader.dylib -thin arm64e -output .build/mip/loader.arm64e.dylib
	codesign --force --sign - .build/mip/loader.arm64e.dylib
	mv .build/mip/loader.arm64e.dylib .build/mip/loader.dylib
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

build-all: app
	$(MAKE) verify

dmg: app
	./packaging/make-dmg.sh $(VERSION) $(APP)

## release-artifacts — the DMG and the checksum file the tap expects

release-artifacts: dmg
	# The checksum file holds one line per asset: the digest, two spaces, the
	# bare file name. The tap reads it next to the asset.
	@cd "$(DERIVED_DATA)" && shasum -a 256 "$(DMG_NAME)" > "$(DMG_NAME).sha256"
	@echo "$(DERIVED_DATA)/$(DMG_NAME).sha256:"
	@cat "$(DERIVED_DATA)/$(DMG_NAME).sha256"

## release — build the artifacts and tag them, without pushing

release:
	@if [ "$(origin VERSION)" != "command line" ]; then \
		echo "error: make release needs a version on the command line, for example: make release VERSION=1.2.3"; \
		exit 1; \
	fi
	# The version is read from the environment here, so a version that holds a
	# quote cannot break out of this command line. Every line below runs only
	# after this check passed, so the version is safe to write out.
	@if ! printf '%s' "$$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$$'; then \
		echo "error: the version \"$(VERSION)\" is not valid. Use MAJOR.MINOR.PATCH, for example 1.2.3."; \
		exit 1; \
	fi
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "error: the working tree is dirty. Commit or stash your changes first."; \
		git status --short; \
		exit 1; \
	fi
	@if git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null; then \
		echo "error: the tag v$(VERSION) already exists."; \
		exit 1; \
	fi
	$(MAKE) release-artifacts VERSION=$(VERSION)
	@if ! bundle_version="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(APP)/Contents/Info.plist")"; then \
		echo "error: the bundle reports no version."; \
		exit 1; \
	fi; \
	if [ "$$bundle_version" != "$(VERSION)" ]; then \
		echo "error: the bundle reports the version $$bundle_version, but $(VERSION) was asked for."; \
		exit 1; \
	fi
	git tag -a "v$(VERSION)" -m "Spaces Renamer $(VERSION)"
	@echo ""
	@echo "Tagged v$(VERSION). Push the commit and the tag with:"
	@echo "  git push origin master v$(VERSION)"

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
	lipo "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.dylib" -verify_arch arm64e
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
	# Apple silicon only: every shipped binary is a thin, arm-only slice.
	test "$$(lipo -archs "$(APP)/Contents/MacOS/SpacesRenamer")" = arm64
	test "$$(lipo -archs "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.dylib")" = arm64e
	test "$$(lipo -archs injection/lib/spaces-renamer.dylib)" = arm64e
	test "$$(lipo -archs "$(APP)/Contents/PlugIns/spaces-renamer.dylib")" = arm64e
	for f in injectd loader.dylib lsdinjector.dylib inject; do \
		lipo injection/mip/$$f -verify_arch arm64e; \
		test "$$(lipo -archs injection/mip/$$f)" = arm64e; \
		lipo "$(APP)/Contents/Resources/mip/$$f" -verify_arch arm64e; \
		test "$$(lipo -archs "$(APP)/Contents/Resources/mip/$$f")" = arm64e; \
	done
	test -f "$(APP)/Contents/Resources/man/man1/sr.1"
	test -f "$(APP)/Contents/_CodeSignature/CodeResources"
	codesign --verify --deep --strict --all-architectures "$(APP)"
	# The legacy run.sh/dylinject layout must no longer be embedded.
	test ! -e "$(APP)/Contents/Resources/Injection"
	# The narrow MIP path must be preferred when a MIP runtime is available.
	grep -Fq '(runtimeEmbedded || systemMIPAvailable) ? .mip : .dyld' "SpacesRenamer/Injector.swift"

clean:
	xcodebuild -project $(PROJECT) -scheme spaces-renamer clean
	swift package --package-path SpacesRenamer clean
	rm -rf "$(APP)"