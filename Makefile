
# the relevant documentation is provided by apple.developer.com, specifically regarding code signing and CFBundles. 
# code signing resource guide:
# https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html

# name of the executable
TARGET = uplink

# stuff to copy over to RESOURCES_DIR
ASSETS_SOURCE_DIR = ui/extra

# directory structure for .dmg :
# https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html#//apple_ref/doc/uid/10000123i-CH101-SW8

BUNDLE_DIR = macos_bundle
# folder used for the universal installer
DMG_DIR = $(BUNDLE_DIR)/Uplink.dmg
# folder used to build the .app
APP_DIR = $(BUNDLE_DIR)/Uplink.app

# contains all subfolders: MacOs, Resources, Frameworks
# https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html#//apple_ref/doc/uid/20001119-110730
APP_CONTENTS_DIR = $(APP_DIR)/Contents

# contains standalone executables
MACOS_DIR = $(APP_CONTENTS_DIR)/MacOs
# contains resources 
RESOURCES_DIR = $(APP_CONTENTS_DIR)/Resources
# contains shared libraries (.dylib)
FRAMEWORKS_DIR = $(APP_CONTENTS_DIR)/Frameworks

all: help

help: ## Print this help message
	@grep -E '^[a-zA-Z._-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

folders: ## creates build directory and copies assets
# 	clean up from previous build
	@rm -rf $(APP_DIR)
	@rm -rf $(DMG_DIR)
	@mkdir -p $(APP_DIR)

# 	this copy command also creates $(APP_CONTENTS_DIR) and $(RESOURCES_DIR)
	@cp -fRp $(ASSETS_SOURCE_DIR)/macos/Uplink.App/Contents $(APP_DIR)
	@mkdir    $(MACOS_DIR)
	@mkdir    $(FRAMEWORKS_DIR)

	@cp -R $(ASSETS_SOURCE_DIR)/assets      $(RESOURCES_DIR)
	@cp -R $(ASSETS_SOURCE_DIR)/images      $(RESOURCES_DIR)
	@cp -R $(ASSETS_SOURCE_DIR)/prism_langs $(RESOURCES_DIR)
	@cp -R $(ASSETS_SOURCE_DIR)/themes      $(RESOURCES_DIR) 

app: folders ## Build the release binary and Uplink.app
	MACOSX_DEPLOYMENT_TARGET="10.11" cargo build --release --target=x86_64-apple-darwin -F production_mode
	MACOSX_DEPLOYMENT_TARGET="10.11" cargo build --release --target=aarch64-apple-darwin -F production_mode
	@lipo target/{x86_64,aarch64}-apple-darwin/release/$(TARGET) -create -output $(MACOS_DIR)/$(TARGET)
	@lipo target/{x86_64,aarch64}-apple-darwin/release/libclear_all.dylib -create -output $(FRAMEWORKS_DIR)/libclear_all.dylib
	@lipo target/{x86_64,aarch64}-apple-darwin/release/libemoji_selector.dylib -create -output $(FRAMEWORKS_DIR)/libemoji_selector.dylib
	
# 	delete all special attributes. not sure why/if this is needed 
	xattr -c $(APP_CONTENTS_DIR)/Info.plist
	xattr -c $(RESOURCES_DIR)/uplink.icns

signed-app: app ## sign the executable, .dylibs, and Uplink.app directory
	/usr/bin/codesign -vvv --deep --entitlements $(ASSETS_DIR)/entitlements.plist --strict --options=runtime --force $(MACOS_DIR)/$(TARGET)
	/usr/bin/codesign -vvv --deep --entitlements $(ASSETS_DIR)/entitlements.plist --strict --options=runtime --force $(FRAMEWORKS_DIR)/libclear_all.dylib
	/usr/bin/codesign -vvv --deep --entitlements $(ASSETS_DIR)/entitlements.plist --strict --options=runtime --force $(FRAMEWORKS_DIR)/libemoji_selector.dylib
	/usr/bin/codesign -vvv --deep --entitlements $(ASSETS_DIR)/entitlements.plist --strict --options=runtime --force $(APP_DIR)

unsigned-dmg: app # build the universal Uplink.dmg file without signing
	@echo "Packing disk image..."
	@ln -sf /Applications $(APP_DIR)/Applications
	@hdiutil create $(DMG_DIR) \
		-volname "Uplink" \
		-fs HFS+ \
		-srcfolder $(APP_DIR) \
		-ov -format UDZO
	@echo "Packed '$(APP_DIR)' into dmg"

dmg: signed-app unsigned-dmg ## sign Uplink.dmg
	/usr/bin/codesign -vvv --deep --entitlements $(ASSETS_DIR)/entitlements.plist --strict --options=runtime --force $(DMG_DIR)

# tell Make that these targets don't correspond to physical files
.PHONY: dmg unsigned-dmg signed-app app folders help all clean
clean: ## Remove all build artifacts
	@cargo clean

