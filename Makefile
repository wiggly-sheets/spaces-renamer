PROJECT := spaces-renamer.xcodeproj
DERIVED_DATA := .build/DerivedData
XCODEBUILD := xcodebuild -project $(PROJECT) -configuration Release -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO

.PHONY: app plugin package-injection universal verify clean

app:
	$(XCODEBUILD) -scheme SpacesRenamer 'ARCHS=arm64 x86_64' build

plugin:
	$(XCODEBUILD) -scheme spaces-renamer 'ARCHS=arm64e x86_64' build

package-injection: plugin
	lipo "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.bundle/Contents/MacOS/spaces-renamer" -thin arm64e -output injection/lib/spaces-renamer.dylib

universal: app package-injection verify

verify:
	lipo -info "$(DERIVED_DATA)/Build/Products/Release/SpacesRenamer.app/Contents/MacOS/SpacesRenamer"
	lipo -info "$(DERIVED_DATA)/Build/Products/Release/spaces-renamer.bundle/Contents/MacOS/spaces-renamer"
	lipo -info injection/lib/spaces-renamer.dylib

clean:
	xcodebuild -project $(PROJECT) -scheme SpacesRenamer clean
	xcodebuild -project $(PROJECT) -scheme spaces-renamer clean
