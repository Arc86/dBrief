APP_NAME = dBrief
EXECUTABLE_NAME = dBrief
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources
MACOS_RESOURCES = $(MACOS)/Resources
MLX_PREBUILT_VERSION = 0.31.3
MLX_PREBUILT_ZIP = .build/mlx-prebuilt/Cmlx-$(MLX_PREBUILT_VERSION).xcframework.zip
MLX_PREBUILT_METALLIB_PATH = Cmlx.xcframework/macos-arm64_x86_64/Cmlx.framework/Versions/A/Resources/default.metallib

# Version is the single source of truth in Info.plist; never hardcode it here.
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/dBrief/Resources/Info.plist)
# Ad-hoc signing by default (we are not in the Apple Developer Program).
# Override with a Developer ID if you ever enroll: make app CODESIGN_IDENTITY="Developer ID Application: …"
CODESIGN_IDENTITY ?= -
DMG_STAGING = .build/dmg
DMG_NAME = $(APP_NAME)-$(VERSION).dmg
# Extra flags passed to `swift build`. The Homebrew formula sets
# SWIFT_BUILD_FLAGS=--disable-sandbox because SwiftPM cannot apply its own
# sandbox while already running inside Homebrew's build sandbox (nested
# sandbox-exec fails). Empty for normal local builds.
SWIFT_BUILD_FLAGS ?=

.PHONY: app run clean build sign dmg

build:
	swift build -c release --arch arm64 $(SWIFT_BUILD_FLAGS)

app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(MACOS) $(RESOURCES) $(MACOS_RESOURCES)
	cp $(BUILD_DIR)/$(EXECUTABLE_NAME) $(MACOS)/$(EXECUTABLE_NAME)
	cp $(BUILD_DIR)/dBriefMLHost $(MACOS)/dBriefMLHost
	if ls $(BUILD_DIR)/*.bundle >/dev/null 2>&1; then cp -R $(BUILD_DIR)/*.bundle $(RESOURCES)/; fi
	cp Sources/dBrief/Resources/Info.plist $(CONTENTS)/Info.plist
	cp Sources/dBrief/Resources/AppIcon.icns $(RESOURCES)/AppIcon.icns
	cp Sources/dBrief/Resources/dBrief-Icon.png $(RESOURCES)/dBrief-Icon.png
	cp Sources/dBrief/Resources/FontAwesome6Brands-Regular.otf $(RESOURCES)/FontAwesome6Brands-Regular.otf
	cp -R Sources/dBrief/Resources/3dPartyIcons $(RESOURCES)/3dPartyIcons
	@set -e; \
	LOCAL_METALLIB="$$(find .build -type f -name 'default.metallib' | head -n 1)"; \
	if [ -n "$$LOCAL_METALLIB" ]; then \
		echo "Using local metallib: $$LOCAL_METALLIB"; \
		cp "$$LOCAL_METALLIB" $(RESOURCES)/default.metallib; \
	else \
		echo "No local metallib found, using prebuilt Cmlx $(MLX_PREBUILT_VERSION) metallib"; \
		mkdir -p .build/mlx-prebuilt; \
		if [ ! -f "$(MLX_PREBUILT_ZIP)" ]; then \
			curl -L -o "$(MLX_PREBUILT_ZIP)" "https://github.com/ml-explore/mlx-swift/releases/download/$(MLX_PREBUILT_VERSION)/Cmlx.xcframework.zip"; \
		fi; \
		unzip -p "$(MLX_PREBUILT_ZIP)" "$(MLX_PREBUILT_METALLIB_PATH)" > $(RESOURCES)/default.metallib; \
	fi
	cp $(RESOURCES)/default.metallib $(RESOURCES)/mlx.metallib
	cp $(RESOURCES)/default.metallib $(MACOS)/default.metallib
	cp $(RESOURCES)/default.metallib $(MACOS)/mlx.metallib
	cp $(RESOURCES)/default.metallib $(MACOS_RESOURCES)/default.metallib
	cp $(RESOURCES)/default.metallib $(MACOS_RESOURCES)/mlx.metallib
	@$(MAKE) sign
	@echo "Built $(APP_BUNDLE) ($(VERSION))"

# Ad-hoc sign the bundle. --deep also signs the nested dBriefMLHost helper executable.
# Strip extended attributes / resource forks first (icns and copied resources can
# carry them), which codesign rejects as "detritus".
sign:
	@echo "Signing $(APP_BUNDLE) with identity: $(CODESIGN_IDENTITY)"
	chmod -R u+w "$(APP_BUNDLE)"
	xattr -cr "$(APP_BUNDLE)"
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" "$(APP_BUNDLE)"
	codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"

# Build a distributable, compressed DMG with a drag-to-Applications target.
dmg: app
	rm -rf "$(DMG_STAGING)" "$(DMG_NAME)"
	mkdir -p "$(DMG_STAGING)"
	cp -R "$(APP_BUNDLE)" "$(DMG_STAGING)/"
	ln -s /Applications "$(DMG_STAGING)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(DMG_NAME)"
	@echo "Built $(DMG_NAME)"

run: app
	pkill -f "$(PWD)/$(APP_BUNDLE)/Contents/MacOS/$(EXECUTABLE_NAME)" || true
	open "$(PWD)/$(APP_BUNDLE)"
	@echo "Launched $(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) $(DMG_STAGING) $(APP_NAME)-*.dmg
