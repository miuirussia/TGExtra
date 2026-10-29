ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

# Modern ld no longer supports Theos's legacy duplicate-symbol option.
_THEOS_TARGET_LDFLAGS := $(subst -multiply_defined suppress,,$(_THEOS_TARGET_LDFLAGS))

TWEAK_NAME = TGExtra

$(TWEAK_NAME)_FILES = $(shell find Sources \( -name '*.swift' -o -name '*.m' -o -name '*.xm' \))
$(TWEAK_NAME)_SWIFTFLAGS = -ISources/tgapiC/include
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -ISources/tgapiC/include -Wno-deprecated-declarations
# Keep Swift and Objective-C class metadata signing consistent on arm64e.
ifeq ($(THEOS_CURRENT_ARCH),arm64e)
$(TWEAK_NAME)_CFLAGS += -fptrauth-objc-class-ro
$(TWEAK_NAME)_SWIFTFLAGS += -sign-class-ro
endif
# Global CCFLAGS also reach Swift's Objective-C importer; scope this to Photos users.
Sources/tgapi/VideoToVoice.xm_CFLAGS = -std=c++11
Sources/tgapi/StoryVideoSave.xm_CFLAGS = -std=c++11
$(TWEAK_NAME)_FRAMEWORKS = CoreServices UIKit CoreLocation MapKit AVFoundation Photos Intents CryptoKit
$(TWEAK_NAME)_LIBRARIES = z sqlite3
$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR = internal

# Copy TGExtra.bundle manually during the packaging step
after-stage::
	@echo ">>> Copying TGExtra.bundle into .deb package..."
	@mkdir -p $(THEOS_STAGING_DIR)/Library/Application\ Support/TGExtra
	@cp -a TGExtra.bundle $(THEOS_STAGING_DIR)/Library/Application\ Support/TGExtra

include $(THEOS_MAKE_PATH)/tweak.mk
