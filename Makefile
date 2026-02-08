APP_NAME = VoiceRecorder
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources

.PHONY: app clean build

build:
	swift build -c release

app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(MACOS) $(RESOURCES)
	cp $(BUILD_DIR)/$(APP_NAME) $(MACOS)/$(APP_NAME)
	cp Sources/VoiceRecorder/Resources/Info.plist $(CONTENTS)/Info.plist
	@echo "Built $(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
