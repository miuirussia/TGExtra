ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TGExtra

$(TWEAK_NAME)_FILES = $(filter-out Sources/tgapiC/Tweak.m,$(shell find Sources \( -name '*.swift' -o -name '*.m' -o -name '*.xm' \)))
$(TWEAK_NAME)_SWIFTFLAGS = -ISources/tgapiC/include
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -ISources/tgapiC/include -Wno-deprecated-declarations
$(TWEAK_NAME)_FRAMEWORKS = CoreServices UIKit CoreLocation MapKit AVFoundation Photos Intents
$(TWEAK_NAME)_LIBRARIES = z
$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR = internal

# Copy TGExtra.bundle manually during the packaging step
after-stage::
	@echo ">>> Copying TGExtra.bundle into .deb package..."
	@mkdir -p $(THEOS_STAGING_DIR)/Library/Application\ Support/TGExtra
	@cp -a TGExtra.bundle $(THEOS_STAGING_DIR)/Library/Application\ Support/TGExtra

include $(THEOS_MAKE_PATH)/tweak.mk
