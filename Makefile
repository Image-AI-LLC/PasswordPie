APP := PasswordPie.app
APPEX := PasswordPieAutoFill.appex
PREFIX ?= $(HOME)/Applications
DEST := $(PREFIX)/$(APP)
# Touch ID's keychain item follows this signing identity. Ad-hoc signatures change
# every rebuild, so a later build can no longer read the saved master password.
SIGN_ID ?= Apple Development: Xun Cai (Y743SM6XYD)
DEVID ?= Developer ID Application: Image AI, LLC (2S468LUF8V)
# Provisioning profiles for the app and the AutoFill extension. The restricted
# autofill-credential-provider entitlement only launches with them embedded; without
# both, the entitlement is stripped from the signing copy so the app still launches.
APP_PROFILE ?=
APPEX_PROFILE ?=
ents = $(if $(and $(APP_PROFILE),$(APPEX_PROFILE)),$(1),build/noprofile/$(notdir $(1)))
MAS_DIR := build/mas
DIRECT_DIR := build/direct

.PHONY: build install icon mas-dev dist-direct clean-channels

build/noprofile/%.entitlements: Entitlements/%.entitlements
	mkdir -p build/noprofile
	sed '/autofill-credential-provider/,+1d' "$<" > "$@"

# Direct channel (the default): includes PP_DIRECT code such as the Chrome password reader.
build:
	swift build -c release

# assemble_app <bin-path> <out-app>: lay out the .app bundle.
define assemble_app
	rm -rf "$(2)"
	mkdir -p "$(2)/Contents/MacOS" "$(2)/Contents/Resources"
	cp "$(1)/PasswordPie" "$(2)/Contents/MacOS/PasswordPie"
	cp Sources/PasswordPieApp/Info.plist "$(2)/Contents/Info.plist"
	cp Assets/AppIcon.icns Assets/Assets.car "$(2)/Contents/Resources/"
	mkdir -p "$(2)/Contents/PlugIns/$(APPEX)/Contents/MacOS"
	cp "$(1)/PasswordPieAutoFill" "$(2)/Contents/PlugIns/$(APPEX)/Contents/MacOS/PasswordPieAutoFill"
	cp Sources/PasswordPieAutoFill/Info.plist "$(2)/Contents/PlugIns/$(APPEX)/Contents/Info.plist"
	$(if $(and $(APP_PROFILE),$(APPEX_PROFILE)),cp "$(APP_PROFILE)" "$(2)/Contents/embedded.provisionprofile" && cp "$(APPEX_PROFILE)" "$(2)/Contents/PlugIns/$(APPEX)/Contents/embedded.provisionprofile")
endef

install: build $(call ents,Entitlements/direct.entitlements) $(call ents,Entitlements/autofill-extension.entitlements)
	$(call assemble_app,$$(swift build -c release --show-bin-path),$(APP))
	@if security find-identity -v -p codesigning | grep -F -q "$(SIGN_ID)"; then \
		codesign --force --sign "$(SIGN_ID)" --entitlements $(call ents,Entitlements/autofill-extension.entitlements) "$(APP)/Contents/PlugIns/$(APPEX)" && \
		codesign --force --sign "$(SIGN_ID)" --entitlements $(call ents,Entitlements/direct.entitlements) "$(APP)"; \
	else \
		echo "warning: $(SIGN_ID) not found; ad-hoc signature drops Touch ID after the next rebuild"; \
		codesign --force --sign - "$(APP)/Contents/PlugIns/$(APPEX)" && codesign --force --sign - "$(APP)"; \
	fi
	mkdir -p "$(PREFIX)"
	rm -rf "$(DEST)"
	cp -R "$(APP)" "$(DEST)"
	@echo "Installed $(DEST)"

# App Store channel, signed for local testing only: sandboxed, no PP_DIRECT code, not installed.
# A real App Store package needs a Distribution certificate and provisioning profile, which this does not use.
mas-dev: $(call ents,Entitlements/mas.entitlements) $(call ents,Entitlements/autofill-extension.entitlements)
	PP_MAS=1 swift build -c release --scratch-path .build-mas
	$(call assemble_app,$$(PP_MAS=1 swift build -c release --scratch-path .build-mas --show-bin-path),$(MAS_DIR)/$(APP))
	codesign --force --sign "$(SIGN_ID)" --entitlements $(call ents,Entitlements/autofill-extension.entitlements) "$(MAS_DIR)/$(APP)/Contents/PlugIns/$(APPEX)"
	codesign --force --sign "$(SIGN_ID)" --entitlements $(call ents,Entitlements/mas.entitlements) "$(MAS_DIR)/$(APP)"
	@codesign -d --entitlements :- "$(MAS_DIR)/$(APP)" 2>/dev/null | grep -q "app-sandbox" && echo "Built sandboxed $(MAS_DIR)/$(APP)"

# Direct channel for download: Developer ID, hardened runtime, zipped for notarization.
# Notarize afterwards (needs a stored notarytool profile):
#   xcrun notarytool submit build/direct/PasswordPie.zip --keychain-profile <profile> --wait
#   xcrun stapler staple build/direct/PasswordPie.app
dist-direct: build $(call ents,Entitlements/direct.entitlements) $(call ents,Entitlements/autofill-extension.entitlements)
	$(call assemble_app,$$(swift build -c release --show-bin-path),$(DIRECT_DIR)/$(APP))
	codesign --force --options runtime --timestamp --sign "$(DEVID)" --entitlements $(call ents,Entitlements/autofill-extension.entitlements) "$(DIRECT_DIR)/$(APP)/Contents/PlugIns/$(APPEX)"
	codesign --force --options runtime --timestamp --sign "$(DEVID)" --entitlements $(call ents,Entitlements/direct.entitlements) "$(DIRECT_DIR)/$(APP)"
	cd $(DIRECT_DIR) && rm -f PasswordPie.zip && ditto -c -k --keepParent $(APP) PasswordPie.zip
	@echo "Built $(DIRECT_DIR)/PasswordPie.zip"

clean-channels:
	rm -rf build .build-mas

# Compile the Icon Composer source into Assets.car (macOS 26+) and AppIcon.icns (older macOS).
# Needs librsvg (rsvg-convert) and Xcode's actool (absolute paths: it may resolve relative ones against a stale $$PWD);
# the compiled files are committed so `make install` does not need Xcode.
icon:
	rsvg-convert -w 1024 -h 1024 "$(CURDIR)/art/source/icon.svg" -o "$(CURDIR)/Assets/AppIcon.icon/Assets/tile.png"
	xcrun actool "$(CURDIR)/Assets/AppIcon.icon" --compile "$(CURDIR)/Assets" --platform macosx --minimum-deployment-target 14.0 \
		--app-icon AppIcon --output-partial-info-plist /dev/null --output-format human-readable-text
