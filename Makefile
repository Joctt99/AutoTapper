# ===========================================================================
#  AutoTapper — Theos 构建脚本（WJHook 机制重写版）
# ===========================================================================
#
#  机制说明:
#   - 产物为纯 ObjC 注入库（%config(generator=internal) + 零 _LIBRARIES），
#     不依赖 CydiaSubstrate/越狱框架，证书签名侧载普通 App 可用。
#   - 屏幕几何完全不碰 UIScreen（iOS 26 注入进程内 UIScreen.mainScreen
#     会信号级 BAD_ACCESS，@try 捕不住）——一律取自 keyWindow。
#   - 触摸模拟为进程内事件派发（UITouch KVC + touchesBegan/Ended +
#     UITouchesEvent 私有类），无 HID/越狱依赖。
#   - 只编 arm64：arm64e 切片老系统 dyld 层崩，侧载不需要。
# ===========================================================================

export TARGET       = iphone:clang:latest:13.0
export ARCHS        = arm64
export THEOS_PACKAGE_SCHEME = rootless
export DEBUG        = 0

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoTapper

AutoTapper_FILES = \
	AutoTapper.xm \
	WJTapCore.m

AutoTapper_CFLAGS = \
	-fobjc-arc \
	-fblocks \
	-Wno-unused-parameter \
	-Wno-deprecated-declarations \
	-Wno-objc-multiple-method-names \
	-Wno-arc-performSelector-leaks

AutoTapper_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics

# 侧载场景：清空 substrate 链接，产物不依赖 CydiaSubstrate
AutoTapper_LIBRARIES =

AutoTapper_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload || killall -9 SpringBoard"
