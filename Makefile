APP_NAME := Sottovoce
# CONFIG=debug enables dev-only tooling (e.g. the settings layout switcher).
CONFIG   ?= release
BUNDLE   := dist/$(APP_NAME).app
BINARY   := .build/$(CONFIG)/$(APP_NAME)
PLIST    := Packaging/Info.plist
ENTITLEMENTS := Packaging/Sottovoce.entitlements
VERSION  := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $(PLIST))
DMG      := dist/$(APP_NAME)-$(VERSION).dmg
ZIP      := dist/$(APP_NAME).zip

# Developer ID is used for dev builds too, so the designated requirement — and
# with it the TCC grants and the Keychain ACLs — is the same one the shipped app
# gets. Falls back to Apple Development, then ad-hoc (permissions re-prompt every
# build). `release` insists on the real Developer ID certificate.
SIGN_IDENTITY  ?= Developer ID Application
# notarytool keychain profile: xcrun notarytool store-credentials sottovoce …
NOTARY_PROFILE ?= sottovoce

.PHONY: build bundle run verify release dmg clean

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp $(PLIST) $(BUNDLE)/Contents/Info.plist
	cp Packaging/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@identity="$(SIGN_IDENTITY)"; timestamp="--timestamp"; \
	if ! security find-identity -p codesigning | grep -q "$$identity"; then \
		if security find-identity -p codesigning | grep -q "Apple Development"; then \
			echo "warning: '$$identity' not found — signing with Apple Development"; \
			identity="Apple Development"; \
		else \
			echo "warning: no signing identity found — ad-hoc signing (permissions will not persist)"; \
			identity="-"; timestamp="--timestamp=none"; \
		fi; \
	fi; \
	set -x; \
	codesign --force --options runtime $$timestamp \
		--entitlements $(ENTITLEMENTS) --sign "$$identity" $(BUNDLE)

run: bundle
	open $(BUNDLE)

verify:
	codesign --verify --strict --verbose=2 $(BUNDLE)
	codesign --display --entitlements - --verbose=2 $(BUNDLE)

# Notarised, stapled disk image. Both the .app and the .dmg are notarised: the
# ticket stapled to the DMG only covers the app while it sits on the mounted
# image, so the app needs its own ticket to launch offline once dragged out.
release: bundle
	@security find-identity -p codesigning | grep -q "Developer ID Application" \
		|| { echo "error: no 'Developer ID Application' certificate in the keychain"; exit 1; }
	$(MAKE) verify
	rm -f $(ZIP)
	ditto -c -k --keepParent $(BUNDLE) $(ZIP)
	xcrun notarytool submit $(ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(BUNDLE)
	rm -f $(ZIP)
	$(MAKE) dmg
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	spctl --assess --type open --context context:primary-signature -vv $(DMG)
	spctl --assess --type exec -vv $(BUNDLE)

dmg:
	Packaging/make-dmg.sh $(APP_NAME) $(BUNDLE) $(DMG)
	codesign --force --timestamp --sign "$(SIGN_IDENTITY)" $(DMG)

clean:
	rm -rf .build dist
