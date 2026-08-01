APP_NAME := Sottovoce
# CONFIG=debug enables dev-only tooling (e.g. the settings layout switcher).
CONFIG   ?= release
BUNDLE   := dist/$(APP_NAME).app
BINARY   := .build/$(CONFIG)/$(APP_NAME)

# Stable signing identity so TCC grants and Keychain access survive rebuilds.
# Must have a real Team ID (Apple Development cert) for Keychain ACLs to be
# stable across builds — self-signed certs fall back to per-binary identity.
# Falls back to ad-hoc (permissions re-prompt every build) if the cert is missing.
SIGN_IDENTITY ?= Apple Development

.PHONY: build bundle run clean

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Packaging/Info.plist $(BUNDLE)/Contents/Info.plist
	@if security find-identity -p codesigning | grep -q "$(SIGN_IDENTITY)"; then \
		echo "codesign --force --sign \"$(SIGN_IDENTITY)\" $(BUNDLE)"; \
		codesign --force --sign "$(SIGN_IDENTITY)" $(BUNDLE); \
	else \
		echo "warning: signing identity '$(SIGN_IDENTITY)' not found — ad-hoc signing (permissions will not persist)"; \
		codesign --force --sign - $(BUNDLE); \
	fi

run: bundle
	open $(BUNDLE)

clean:
	rm -rf .build dist
