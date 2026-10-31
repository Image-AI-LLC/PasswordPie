APP := PasswordPie.app
PREFIX ?= $(HOME)/Applications
DEST := $(PREFIX)/$(APP)
# Touch ID's keychain item follows this signing identity. Ad-hoc signatures change
# every rebuild, so a later build can no longer read the saved master password.
SIGN_ID ?= Apple Development: Xun Cai (Y743SM6XYD)

.PHONY: build install icon

build:
	swift build -c release --product PasswordPie

install: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$$(swift build -c release --product PasswordPie --show-bin-path)/PasswordPie" "$(APP)/Contents/MacOS/PasswordPie"
	cp Sources/PasswordPieApp/Info.plist "$(APP)/Contents/Info.plist"
	mkdir -p "$(APP)/Contents/Resources"
	cp Assets/AppIcon.icns Assets/Assets.car "$(APP)/Contents/Resources/"
	@if security find-identity -v -p codesigning | grep -F -q "$(SIGN_ID)"; then \
		codesign --force --sign "$(SIGN_ID)" "$(APP)"; \
	else \
		echo "warning: $(SIGN_ID) not found; ad-hoc signature drops Touch ID after the next rebuild"; \
		codesign --force --sign - "$(APP)"; \
	fi
	mkdir -p "$(PREFIX)"
	rm -rf "$(DEST)"
	cp -R "$(APP)" "$(DEST)"
	@echo "Installed $(DEST)"

# Compile the Icon Composer source into Assets.car (macOS 26+) and AppIcon.icns (older macOS).
# Needs Xcode's actool (absolute paths: it may resolve relative ones against a stale $$PWD);
# the compiled files are committed so `make install` does not need Xcode.
icon:
	xcrun actool "$(CURDIR)/Assets/AppIcon.icon" --compile "$(CURDIR)/Assets" --platform macosx --minimum-deployment-target 14.0 \
		--app-icon AppIcon --output-partial-info-plist /dev/null --output-format human-readable-text
