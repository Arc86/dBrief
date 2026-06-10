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

# Static ffmpeg bundled into the app so DMG users get full audio processing
# (mix/DSP/AAC encode/segmentation) without installing Homebrew.
# Source: martin-riedl.de static macOS arm64 build (alternatives: osxexperts.net).
# The SHA256 is the lock; the URL is only a fetch hint. After the first build,
# paste the printed SHA256 into FFMPEG_SHA256 to make builds reproducible and verified.
FFMPEG_VERSION ?= latest
FFMPEG_URL ?= https://ffmpeg.martin-riedl.de/redirect/$(FFMPEG_VERSION)/macos/arm64/release/ffmpeg.zip
FFMPEG_SHA256 ?= ef4fe121377039053b0d7bed4a9aa46e7912918f5ba6424a1dd155f4eed625b0
FFMPEG_CACHE = .build/ffmpeg

# Version is the single source of truth in Info.plist; never hardcode it here.
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/dBrief/Resources/Info.plist)
# Ad-hoc signing by default (we are not in the Apple Developer Program).
# Override with a Developer ID if you ever enroll: make app CODESIGN_IDENTITY="Developer ID Application: …"
CODESIGN_IDENTITY ?= -
DMG_STAGING = .build/dmg
DMG_NAME = $(APP_NAME)-$(VERSION).dmg

.PHONY: app run clean build sign dmg

build:
	swift build -c release --arch arm64

app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(MACOS) $(RESOURCES) $(MACOS_RESOURCES)
	cp $(BUILD_DIR)/$(EXECUTABLE_NAME) $(MACOS)/$(EXECUTABLE_NAME)
	cp $(BUILD_DIR)/dBriefMLHost $(MACOS)/dBriefMLHost
	if ls $(BUILD_DIR)/*.bundle >/dev/null 2>&1; then cp -R $(BUILD_DIR)/*.bundle $(RESOURCES)/; fi
	@set -e; \
	mkdir -p $(FFMPEG_CACHE); \
	FFMPEG_BIN="$(FFMPEG_CACHE)/ffmpeg"; \
	if [ ! -x "$$FFMPEG_BIN" ]; then \
		echo "Downloading static ffmpeg ($(FFMPEG_VERSION), macos arm64)…"; \
		curl -L -o "$(FFMPEG_CACHE)/ffmpeg.zip" "$(FFMPEG_URL)"; \
		unzip -o -j "$(FFMPEG_CACHE)/ffmpeg.zip" -d "$(FFMPEG_CACHE)"; \
		chmod +x "$$FFMPEG_BIN"; \
	fi; \
	ACTUAL_SHA="$$(shasum -a 256 "$$FFMPEG_BIN" | awk '{print $$1}')"; \
	if [ -n "$(FFMPEG_SHA256)" ]; then \
		if [ "$$ACTUAL_SHA" != "$(FFMPEG_SHA256)" ]; then \
			echo "ERROR: bundled ffmpeg SHA256 mismatch (expected $(FFMPEG_SHA256), got $$ACTUAL_SHA)." >&2; \
			echo "       The upstream artifact changed; re-pin FFMPEG_SHA256 after auditing." >&2; \
			exit 1; \
		fi; \
		echo "ffmpeg SHA256 verified ($$ACTUAL_SHA)."; \
	else \
		echo "WARNING: FFMPEG_SHA256 is unset — bundling unverified ffmpeg."; \
		echo "         Pin this SHA256 in the Makefile for reproducible builds:"; \
		echo "           $$ACTUAL_SHA"; \
	fi; \
	cp "$$FFMPEG_BIN" $(MACOS)/ffmpeg; \
	chmod +x $(MACOS)/ffmpeg
	cp packaging/FFMPEG-NOTICE.txt $(RESOURCES)/FFMPEG-NOTICE.txt
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
