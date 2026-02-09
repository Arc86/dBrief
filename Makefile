APP_NAME = DeBrief
EXECUTABLE_NAME = VoiceRecorder
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
	cp $(BUILD_DIR)/$(EXECUTABLE_NAME) $(MACOS)/$(EXECUTABLE_NAME)
	cp Sources/VoiceRecorder/Resources/Info.plist $(CONTENTS)/Info.plist
	cp Sources/VoiceRecorder/Resources/AppIcon.icns $(RESOURCES)/AppIcon.icns
	cp Sources/VoiceRecorder/Resources/DeBrief-Icon.png $(RESOURCES)/DeBrief-Icon.png
	@echo "Built $(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
