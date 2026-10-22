TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BTRename
BTRename_FILES = Tweak.x
BTRename_FRAMEWORKS = UIKit Foundation
BTRename_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
