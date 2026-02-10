APP_NAME = dBrief
EXECUTABLE_NAME = dBrief
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
	cp Sources/dBrief/Resources/Info.plist $(CONTENTS)/Info.plist
	cp Sources/dBrief/Resources/AppIcon.icns $(RESOURCES)/AppIcon.icns
	cp Sources/dBrief/Resources/dBrief-Icon.png $(RESOURCES)/dBrief-Icon.png
	cp Sources/dBrief/Resources/FontAwesome6Brands-Regular.otf $(RESOURCES)/FontAwesome6Brands-Regular.otf
	cp -R Sources/dBrief/Resources/3dPartyIcons $(RESOURCES)/3dPartyIcons
	@echo "Built $(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
