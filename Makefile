APP := PasswordPie.app
APPEX := PasswordPieAutoFill.appex
SAFARI_APPEX := PasswordPieSafari.appex
HOST := PasswordPieBrowserHost
HOST_ID := com.oldcai.passwordpie.browser-host
# The browser extension (WXT). The Safari build goes inside the Safari appex; the Chrome build is loaded unpacked
# or uploaded to the Chrome Web Store. Needs Node and pnpm.
SAFARI_EXT := extension/.output/safari-mv3
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

.PHONY: build extension extension-mas install icon site-icons mas-dev dist-direct clean-channels

build/noprofile/%.entitlements: Entitlements/%.entitlements
	mkdir -p build/noprofile
	sed '/autofill-credential-provider/,+1d' "$<" > "$@"

# Direct channel (the default): includes PP_DIRECT code such as the Chrome password reader.
build:
	swift build -c release

extension:
	cd extension && pnpm install --frozen-lockfile && pnpm build:chrome && pnpm build:safari

# The Safari build inside the App Store app. The extension has no account, and its Safari build has no line that opens
# the site, so it is the same build as the direct channel's (docs/ACCOUNTS.md, "App Store rules").
extension-mas:
	cd extension && pnpm install --frozen-lockfile && pnpm build:safari

# assemble_app <bin-path> <out-app> [with-chrome-host]: lay out the .app bundle. The Chrome host is direct channel only.
define assemble_app
	rm -rf "$(2)"
	mkdir -p "$(2)/Contents/MacOS" "$(2)/Contents/Resources"
	cp "$(1)/PasswordPie" "$(2)/Contents/MacOS/PasswordPie"
	cp Sources/PasswordPieApp/Info.plist "$(2)/Contents/Info.plist"
	cp Assets/AppIcon.icns Assets/Assets.car "$(2)/Contents/Resources/"
	mkdir -p "$(2)/Contents/Resources/SiteIcons"
	cp Assets/SiteIcons/*.png "$(2)/Contents/Resources/SiteIcons/"
	mkdir -p "$(2)/Contents/PlugIns/$(APPEX)/Contents/MacOS"
	cp "$(1)/PasswordPieAutoFill" "$(2)/Contents/PlugIns/$(APPEX)/Contents/MacOS/PasswordPieAutoFill"
	cp Sources/PasswordPieAutoFill/Info.plist "$(2)/Contents/PlugIns/$(APPEX)/Contents/Info.plist"
	$(if $(and $(APP_PROFILE),$(APPEX_PROFILE)),cp "$(APP_PROFILE)" "$(2)/Contents/embedded.provisionprofile" && cp "$(APPEX_PROFILE)" "$(2)/Contents/PlugIns/$(APPEX)/Contents/embedded.provisionprofile")
	mkdir -p "$(2)/Contents/PlugIns/$(SAFARI_APPEX)/Contents/MacOS" "$(2)/Contents/PlugIns/$(SAFARI_APPEX)/Contents/Resources"
	cp "$(1)/PasswordPieSafari" "$(2)/Contents/PlugIns/$(SAFARI_APPEX)/Contents/MacOS/PasswordPieSafari"
	cp Sources/PasswordPieSafari/Info.plist "$(2)/Contents/PlugIns/$(SAFARI_APPEX)/Contents/Info.plist"
	cp -R "$(SAFARI_EXT)/." "$(2)/Contents/PlugIns/$(SAFARI_APPEX)/Contents/Resources/"
	$(if $(3),cp "$(1)/$(HOST)" "$(2)/Contents/MacOS/$(HOST)")
endef

# sign_app_sh <app> <codesign flags> <app entitlements> [with-chrome-host]: nested code first, the app last, joined
# with && so it also works inside one shell line.
sign_app_sh = $(if $(4),codesign --force $(2) --identifier $(HOST_ID) --entitlements Entitlements/browser-host.entitlements "$(1)/Contents/MacOS/$(HOST)" && )codesign --force $(2) --entitlements Entitlements/safari-extension.entitlements "$(1)/Contents/PlugIns/$(SAFARI_APPEX)" && codesign --force $(2) --entitlements $(call ents,Entitlements/autofill-extension.entitlements) "$(1)/Contents/PlugIns/$(APPEX)" && codesign --force $(2) --entitlements $(3) "$(1)"

# sign_app: the same, as one recipe line.
sign_app = $(call sign_app_sh,$(1),$(2),$(3),$(4))

# Your own install also trusts the Premium test key (`PP_DEV_EXTENSION`, see EntitlementToken.trustedKeys), whose private
# half is public for the mock site. Distributed builds do not.
install: extension $(call ents,Entitlements/direct.entitlements) $(call ents,Entitlements/autofill-extension.entitlements)
	swift build -c release -Xswiftc -DPP_DEV_EXTENSION
	$(call assemble_app,$$(swift build -c release -Xswiftc -DPP_DEV_EXTENSION --show-bin-path),$(APP),host)
	@if security find-identity -v -p codesigning | grep -F -q "$(SIGN_ID)"; then \
		$(call sign_app_sh,$(APP),--sign "$(SIGN_ID)",$(call ents,Entitlements/direct.entitlements),host); \
	else \
		echo "warning: $(SIGN_ID) not found; ad-hoc signature drops Touch ID after the next rebuild, and the browser extensions will not connect"; \
		$(call sign_app_sh,$(APP),--sign -,$(call ents,Entitlements/direct.entitlements),host); \
	fi
	mkdir -p "$(PREFIX)"
	rm -rf "$(DEST)"
	cp -R "$(APP)" "$(DEST)"
	@echo "Installed $(DEST)"

# App Store channel, signed for local testing only: sandboxed, no PP_DIRECT code, not installed.
# A real App Store package needs a Distribution certificate and provisioning profile, which this does not use.
mas-dev: extension-mas $(call ents,Entitlements/mas.entitlements) $(call ents,Entitlements/autofill-extension.entitlements)
	PP_MAS=1 swift build -c release --scratch-path .build-mas
	$(call assemble_app,$$(PP_MAS=1 swift build -c release --scratch-path .build-mas --show-bin-path),$(MAS_DIR)/$(APP))
	$(call sign_app,$(MAS_DIR)/$(APP),--sign "$(SIGN_ID)",$(call ents,Entitlements/mas.entitlements))
	@codesign -d --entitlements :- "$(MAS_DIR)/$(APP)" 2>/dev/null | grep -q "app-sandbox" && echo "Built sandboxed $(MAS_DIR)/$(APP)"

# Direct channel for download: Developer ID, hardened runtime, zipped for notarization.
# For a release, use Scripts/release-direct.sh (notarizes, staples and builds the DMG). By hand:
#   xcrun notarytool submit build/direct/PasswordPie.zip --keychain-profile <profile> --wait
#   xcrun stapler staple build/direct/PasswordPie.app
dist-direct: build extension $(call ents,Entitlements/direct.entitlements) $(call ents,Entitlements/autofill-extension.entitlements)
	$(call assemble_app,$$(swift build -c release --show-bin-path),$(DIRECT_DIR)/$(APP),host)
	$(call sign_app,$(DIRECT_DIR)/$(APP),--options runtime --timestamp --sign "$(DEVID)",$(call ents,Entitlements/direct.entitlements),host)
	cd $(DIRECT_DIR) && rm -f PasswordPie.zip && ditto -c -k --keepParent $(APP) PasswordPie.zip
	@echo "Built $(DIRECT_DIR)/PasswordPie.zip"

clean-channels:
	rm -rf build .build-mas

# Refetch the bundled site icons (Assets/SiteIcons, top 100 sites) on this Mac. The app never fetches icons itself.
site-icons:
	python3 -I Scripts/fetch_site_icons.py

# Compile the Icon Composer source into Assets.car (macOS 26+) and AppIcon.icns (older macOS).
# Needs librsvg (rsvg-convert) and Xcode's actool (absolute paths: it may resolve relative ones against a stale $$PWD);
# the compiled files are committed so `make install` does not need Xcode.
icon:
	rsvg-convert -w 1024 -h 1024 "$(CURDIR)/art/source/icon.svg" -o "$(CURDIR)/Assets/AppIcon.icon/Assets/tile.png"
	xcrun actool "$(CURDIR)/Assets/AppIcon.icon" --compile "$(CURDIR)/Assets" --platform macosx --minimum-deployment-target 14.0 \
		--app-icon AppIcon --output-partial-info-plist /dev/null --output-format human-readable-text
