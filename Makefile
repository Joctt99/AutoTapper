# ===========================================================================
#  AutoTapper — Theos 构建脚本
#  目标: iPhone 13 Pro / iOS 17.0 (arm64 + arm64e, rootless)
# ===========================================================================
#
#  说明:
#   - THEOS_PACKAGE_SCHEME=rootless 让 Theos 把产物装到 /var/jb/
#     (dopamine / palera1n rootless / ellekit 都是这个布局)
#   - TARGET 最低 13.0：代码里用到 UIWindowScene(13.0+)，
#     低版本走 initWithFrame: 分支，所以不需要 #if 包。
#   - 私有符号(IOHIDEvent / GSSendEvent / AVSystemController)全部用
#     dlsym 运行时解析，不静态链接，避免私有 framework 链接失败。
# ===========================================================================

export TARGET       = iphone:clang:latest:13.0
export ARCHS        = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless
export DEBUG        = 0

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoTapper

# Logos 入口 / 音量键 Logos hook / 各功能模块
AutoTapper_FILES = \
	AutoTapper.xm \
	Tweak.xm \
	YGCore.m \
	YGConfig.m \
	YGHID.m \
	YGTouchInjector.m \
	YGTapEngine.m \
	YGVolumeButton.m \
	YGOverlayWindow.m \
	YGOverlayController.m

AutoTapper_CFLAGS = \
	-fobjc-arc \
	-fblocks \
	-Wno-unused-parameter \
	-Wno-deprecated-declarations \
	-Wno-objc-multiple-method-names \
	-Wno-arc-performSelector-leaks \
	-DYG_TWEAK=1

AutoTapper_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics

# 侧载（证书签名）场景：清空 substrate 链接，产物不依赖 CydiaSubstrate，
# 否则注入普通 App 后 dyld 找不到 @rpath/CydiaSubstrate.framework 直接闪退。
# 配合两个 .xm 顶部的 %config(generator=internal)，hook 走 objc runtime。
AutoTapper_LIBRARIES =

# GSEvent 旧后端默认关闭（iOS 15+ 的 purple port 已不再接受进程外事件）；
# 需要在 iOS 13/14 上试旧路时可打开： make ... ADDITIONAL_CFLAGS=-DYG_ENABLE_GSEVENT=1
AutoTapper_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload || killall -9 SpringBoard"
