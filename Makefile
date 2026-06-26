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
# Signing identity. "auto" (default) creates/reuses a *stable* self-signed
# code-signing certificate via scripts/ensure-signing-cert.sh. A stable identity
# is what lets macOS TCC (Screen Recording, etc.) survive app updates instead of
# silently invalidating the grant on every release (ad-hoc signing changes the
# code hash each build). Override with "-" for pure ad-hoc, or with a
# "Developer ID Application: …" if you ever enroll in the Apple Developer Program.
CODESIGN_IDENTITY ?= auto
SIGNING_CERT_NAME ?= dBrief Self-Signed
# Hardened-runtime entitlements, applied only on the Developer ID path (needed
# for notarization). Harmless/unused for the ad-hoc and self-signed paths.
ENTITLEMENTS = packaging/dBrief.entitlements
# notarytool keychain profile for `make notarize` (see RELEASING.md). Empty = off.
NOTARY_PROFILE ?=
DMG_STAGING = .build/dmg
DMG_NAME = $(APP_NAME)-$(VERSION).dmg

.PHONY: app run clean build sign dmg package-dmg notarize

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
	@set -e; \
	SPARKLE_FW="$$(find .build -type d -name 'Sparkle.framework' -path '*release*' | head -n 1)"; \
	if [ -z "$$SPARKLE_FW" ]; then SPARKLE_FW="$$(find .build -type d -name 'Sparkle.framework' | head -n 1)"; fi; \
	if [ -z "$$SPARKLE_FW" ]; then \
		echo "ERROR: Sparkle.framework not found under .build — run 'swift build' first." >&2; exit 1; fi; \
	echo "Embedding Sparkle.framework from $$SPARKLE_FW"; \
	mkdir -p "$(CONTENTS)/Frameworks"; \
	rm -rf "$(CONTENTS)/Frameworks/Sparkle.framework"; \
	cp -R "$$SPARKLE_FW" "$(CONTENTS)/Frameworks/Sparkle.framework"; \
	if ! otool -l "$(MACOS)/$(EXECUTABLE_NAME)" | grep -q "@executable_path/../Frameworks"; then \
		install_name_tool -add_rpath "@executable_path/../Frameworks" "$(MACOS)/$(EXECUTABLE_NAME)"; \
	fi
	@$(MAKE) sign
	@echo "Built $(APP_BUNDLE) ($(VERSION))"

# Sign the bundle. --deep also signs the nested dBriefMLHost helper executable.
# Strip extended attributes / resource forks first (icns and copied resources can
# carry them), which codesign rejects as "detritus".
# When CODESIGN_IDENTITY is "auto" we resolve a stable self-signed cert (so TCC
# permissions persist across releases), falling back to ad-hoc "-" if it can't
# be created — the app still builds, it just resets permissions on each release.
sign:
	@set -e; \
	IDENTITY="$(CODESIGN_IDENTITY)"; \
	if [ "$$IDENTITY" = "auto" ]; then \
		IDENTITY="$$(SIGNING_CERT_NAME='$(SIGNING_CERT_NAME)' ./scripts/ensure-signing-cert.sh)" || { \
			echo "WARNING: could not create a stable self-signed cert; falling back to ad-hoc (-)." >&2; \
			echo "         Screen Recording (and other restart-only permissions) will reset on each release." >&2; \
			IDENTITY="-"; \
		}; \
	fi; \
	IDENTITY="$${IDENTITY:--}"; \
	echo "Signing $(APP_BUNDLE) with identity: $$IDENTITY"; \
	chmod -R u+w "$(APP_BUNDLE)"; \
	xattr -cr "$(APP_BUNDLE)"; \
	case "$$IDENTITY" in \
	"Developer ID Application:"*) \
		echo "Developer ID — hardened runtime + secure timestamp (notarization-ready)"; \
		codesign --force --options runtime --timestamp --sign "$$IDENTITY" "$(MACOS)/ffmpeg"; \
		codesign --force --options runtime --timestamp --entitlements "$(ENTITLEMENTS)" --sign "$$IDENTITY" "$(MACOS)/dBriefMLHost"; \
		: 'Sign nested code INSIDE-OUT. The .metallib files in MacOS/ are Mach-O ("MetalLib executable"); they MUST be signed before the main executable, because signing $(EXECUTABLE_NAME) (the bundle main exe) triggers a bundle-level seal that rejects any unsigned nested code. (--deep handles this automatically on the self-signed path below.)'; \
		find "$(MACOS)" -name '*.metallib' -exec codesign --force --options runtime --timestamp --sign "$$IDENTITY" {} \;; \
		: 'Sign the embedded Sparkle.framework inside-out (XPC services, Autoupdate/Updater.app helpers, then the framework) BEFORE the main executable, so the bundle-level seal accepts it. The self-signed branch below relies on --deep instead.'; \
		if [ -d "$(CONTENTS)/Frameworks/Sparkle.framework" ]; then \
			SPK="$(CONTENTS)/Frameworks/Sparkle.framework"; \
			find "$$SPK" -name '*.xpc' -exec codesign --force --options runtime --timestamp --sign "$$IDENTITY" {} \;; \
			find "$$SPK" -name 'Autoupdate' -type f -exec codesign --force --options runtime --timestamp --sign "$$IDENTITY" {} \;; \
			find "$$SPK" -name 'Updater.app' -type d -exec codesign --force --options runtime --timestamp --sign "$$IDENTITY" {} \;; \
			codesign --force --options runtime --timestamp --sign "$$IDENTITY" "$$SPK"; \
		fi; \
		codesign --force --options runtime --timestamp --entitlements "$(ENTITLEMENTS)" --sign "$$IDENTITY" "$(MACOS)/$(EXECUTABLE_NAME)"; \
		codesign --force --options runtime --timestamp --entitlements "$(ENTITLEMENTS)" --sign "$$IDENTITY" "$(APP_BUNDLE)"; \
		;; \
	*) \
		if ! codesign --force --deep --sign "$$IDENTITY" "$(APP_BUNDLE)"; then \
			if [ "$$IDENTITY" != "-" ]; then \
				echo "WARNING: codesign with '$$IDENTITY' failed (identity not usable in this" >&2; \
				echo "         environment — e.g. a Homebrew build's keychain search list);" >&2; \
				echo "         falling back to ad-hoc (-). Screen Recording (and other" >&2; \
				echo "         restart-only permissions) may reset on each rebuild." >&2; \
				codesign --force --deep --sign - "$(APP_BUNDLE)"; \
			else \
				exit 1; \
			fi; \
		fi; \
		;; \
	esac; \
	codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"

# Build a distributable, compressed DMG with a drag-to-Applications target.
dmg: app package-dmg

# Assemble the DMG from the *already-built* $(APP_BUNDLE) without rebuilding or
# re-signing it. Split out so `notarize` can staple the app before packaging.
package-dmg:
	rm -rf "$(DMG_STAGING)" "$(DMG_NAME)"
	mkdir -p "$(DMG_STAGING)"
	cp -R "$(APP_BUNDLE)" "$(DMG_STAGING)/"
	ln -s /Applications "$(DMG_STAGING)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(DMG_NAME)"
	@echo "Built $(DMG_NAME)"

# Notarized Developer ID release (optional — requires Apple Developer Program
# enrollment). Hardened-signs the app, notarizes & staples it, packages the DMG,
# then notarizes & staples the DMG so download users skip the Gatekeeper prompt.
# One-time setup + usage are documented in RELEASING.md. Run e.g.:
#   make notarize CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=dbrief
notarize:
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "ERROR: set NOTARY_PROFILE=<notarytool keychain profile>; see RELEASING.md." >&2; exit 1; fi
	@case "$(CODESIGN_IDENTITY)" in "Developer ID Application:"*) ;; \
		*) echo "ERROR: set CODESIGN_IDENTITY=\"Developer ID Application: …\" to notarize." >&2; exit 1;; esac
	$(MAKE) app CODESIGN_IDENTITY='$(CODESIGN_IDENTITY)'
	@echo "Submitting $(APP_BUNDLE) for notarization…"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(BUILD_DIR)/$(APP_NAME)-notarize.zip"
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME)-notarize.zip" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUNDLE)"
	rm -f "$(BUILD_DIR)/$(APP_NAME)-notarize.zip"
	$(MAKE) package-dmg
	@echo "Submitting $(DMG_NAME) for notarization…"
	xcrun notarytool submit "$(DMG_NAME)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG_NAME)"
	@echo "Notarized & stapled $(DMG_NAME)"

run: app
	pkill -f "$(PWD)/$(APP_BUNDLE)/Contents/MacOS/$(EXECUTABLE_NAME)" || true
	open "$(PWD)/$(APP_BUNDLE)"
	@echo "Launched $(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) $(DMG_STAGING) $(APP_NAME)-*.dmg
