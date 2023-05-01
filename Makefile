TARGET = uplink

ASSETS_DIR = ./ui/extra
RELEASE_DIR = ./target/release

APP_NAME = Uplink.app
APP_TEMPLATE = $(ASSETS_DIR)/macos/$(APP_NAME)
APP_DIR = $(RELEASE_DIR)/macos
APP_BINARY = $(RELEASE_DIR)/$(TARGET)
CONTENTS = $(APP_DIR)/$(APP_NAME)/Contents
APP_BINARY_DIR = $(APP_DIR)/$(APP_NAME)/Contents/MacOS
APP_EXTRAS_DIR = $(APP_DIR)/$(APP_NAME)/Contents/Resources

DMG_NAME = Uplink.dmg
DMG_DIR = $(RELEASE_DIR)/macos

vpath $(TARGET) $(RELEASE_DIR)
vpath $(APP_NAME) $(APP_DIR)
vpath $(DMG_NAME) $(APP_DIR)

all: help

help: ## Print this help message
	@grep -E '^[a-zA-Z._-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

binary: $(TARGET)-native ## Build a release binary
binary-universal: $(TARGET)-universal ## Build a universal release binary
$(TARGET)-native:
	MACOSX_DEPLOYMENT_TARGET="10.11" cargo build --release -F production_mode
	@lipo target/release/$(TARGET) -create -output $(APP_BINARY)
$(TARGET)-universal:
	MACOSX_DEPLOYMENT_TARGET="10.11" cargo build --release --target=x86_64-apple-darwin -F production_mode
	MACOSX_DEPLOYMENT_TARGET="10.11" cargo build --release --target=aarch64-apple-darwin -F production_mode
	@lipo target/{x86_64,aarch64}-apple-darwin/release/$(TARGET) -create -output $(APP_BINARY)
	@lipo target/{x86_64,aarch64}-apple-darwin/release/libclear_all.dylib -create -output $(RELEASE_DIR)/libclear_all.dylib
	@lipo target/{x86_64,aarch64}-apple-darwin/release/libemoji_selector.dylib -create -output $(RELEASE_DIR)/libemoji_selector.dylib
	/usr/bin/codesign -vvv --deep --entitlements $(ASSETS_DIR)/entitlements.plist --strict --options=runtime --force $(APP_BINARY)
	/usr/bin/codesign -vvv --deep --entitlements $(ASSETS_DIR)/entitlements.plist --strict --options=runtime --force $(RELEASE_DIR)/libclear_all.dylib
	/usr/bin/codesign -vvv --deep --entitlements $(ASSETS_DIR)/entitlements.plist --strict --options=runtime --force $(RELEASE_DIR)/libemoji_selector.dylib

app: $(APP_NAME)-native ## Create a Uplink.app
app-universal: $(APP_NAME)-universal ## Create a universal Uplink.app
$(APP_NAME)-%: $(TARGET)-%
	@mkdir -p $(APP_BINARY_DIR)
	@mkdir -p $(APP_EXTRAS_DIR)
	@cp -fRp $(APP_TEMPLATE) $(APP_DIR)
	@cp -fp $(APP_BINARY) $(APP_BINARY_DIR)
	@touch -r "$(APP_BINARY)" "$(APP_DIR)/$(APP_NAME)"
	@echo "Created '$(APP_NAME)' in '$(APP_DIR)'"
	xattr -c $(APP_DIR)/$(APP_NAME)/Contents/Info.plist
	xattr -c $(APP_DIR)/$(APP_NAME)/Contents/Resources/uplink.icns

	mkdir -p $(APP_DIR)/$(APP_NAME)/Contents/Resources/extra
	cp -r ./ui/extra/assets      $(APP_DIR)/$(APP_NAME)/Contents/Resources/extra
	cp -r ./ui/extra/images      $(APP_DIR)/$(APP_NAME)/Contents/Resources/extra
	cp -r ./ui/extra/prism_langs $(APP_DIR)/$(APP_NAME)/Contents/Resources/extra
	cp -r ./ui/extra/themes      $(APP_DIR)/$(APP_NAME)/Contents/Resources/extra

	mkdir -p $(APP_DIR)/$(APP_NAME)/Contents/Resources/extensions
	cp $(RELEASE_DIR)/*.dylib $(APP_DIR)/$(APP_NAME)/Contents/Resources/extensions
# sign target/macos/Uplink.app
	/usr/bin/codesign -vvv --deep --entitlements $(ASSETS_DIR)/entitlements.plist --strict --options=runtime --force $(APP_DIR)/$(APP_NAME)

dmg: $(DMG_NAME)-native ## Create a Uplink.dmg
dmg-universal: $(DMG_NAME)-universal ## Create a universal Uplink.dmg
$(DMG_NAME)-%: $(APP_NAME)-%
	@echo "Packing disk image..."
	@ln -sf /Applications $(DMG_DIR)/Applications
	@hdiutil create $(DMG_DIR)/$(DMG_NAME) \
		-volname "Uplink" \
		-fs HFS+ \
		-srcfolder $(APP_DIR) \
		-ov -format UDZO
	@echo "Packed '$(APP_NAME)' in '$(APP_DIR)'"
# sign target/macos/Uplink.dmg
	/usr/bin/codesign -vvv --deep --entitlements $(ASSETS_DIR)/entitlements.plist --strict --options=runtime --force $(DMG_DIR)/$(DMG_NAME)

install: $(INSTALL)-native ## Mount disk image
install-universal: $(INSTALL)-native ## Mount universal disk image
$(INSTALL)-%: $(DMG_NAME)-%
	@open $(DMG_DIR)/$(DMG_NAME)

.PHONY: app binary clean dmg install $(TARGET) $(TARGET)-universal

clean: ## Remove all build artifacts
	@cargo clean
watch: ## run this first: `cargo install cargo-watch`
	@cargo watch -x 'run'
