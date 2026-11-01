//
//  YGCore.h — AutoTapper 公共头
//
//  iPhone 13 Pro / iOS 17.0, rootless jailbreak (palera1n / dopamine + ellekit)
//
//  ── 设计要点（先读这段，再看代码）─────────────────────────────────────────────
//
//  1) 点击注入：按「探测 → 优先 → 回退」在运行时选后端
//       HID      : IOHIDEventCreateDigitizerFingerEvent
//                  + IOHIDEventSystemClientCreateWithType(Inject)
//                  + IOHIDEventSystemClientDispatchEvent
//                  iOS 17 上函数仍在（见 YGHID.m 顶部的可用性表）。
//                  ★ 只有它能把事件从 SpringBoard 投到「前台任意 App」。
//       SPRINGHID: 同一份 IOHIDEvent，改走 -[UIApplication _enqueueHIDEvent:]
//                  进 SpringBoard 自己的 HID 队列（iOS 15/16 常见，iOS 17 视机型）。
//       UITOUCH  : 伪造 UITouch/UIEvent → -[UIApplication _dispatchTouches:event:]
//                  纯进程内，只在「被注入的那个进程」里生效。
//       SENDEVENT: 伪造 UIEvent → 公开 API -[UIApplication sendEvent:]
//       GSEVENT  : iOS 13/14 考古分支，需 -DYG_ENABLE_GSEVENT=1，默认不编译。
//
//  2) 音量减键：三层，任一层命中即触发，300ms 去抖
//       L1 IOHIDEventSystemClient 监听 keyboard usage 0xEA  ← 最可靠，音量到底了也收得到
//       L2 AVSystemController_SystemVolumeDidChangeNotification
//          （iOS 15/16/17 都还能收到，但音量已为 0 时不再触发）
//       L3 swizzle SBVolumeControl -_changeVolumeBy: / SBVolumeHardwareButton
//          （代替 MediaRemote：MediaRemote 只能发命令、收不到按键，iOS 16 起更难用）
//
//  3) 悬浮窗：独立 UIWindow，windowLevel = UIWindowLevelAlert + 2000。
//     iOS 13+ 没有 app.keyWindow，一律从 connectedScenes 里挑 active 的 UIWindowScene；
//     scene 断开/切换时重建窗口（UIWindow.windowScene 只读，不能改绑）。
//     根视图重写 hitTest:，只在自己的可交互子视图范围内拦触摸，其余穿透到下层 App。
//

#ifndef YG_CORE_H
#define YG_CORE_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark - 通知名

extern NSString *const YGLogDidAppendNotification;
extern NSString *const YGTapEngineDidStopNotification;
extern NSString *const YGTapEngineDidFailStartNotification;

#pragma mark - 日志

#define YGLOG(fmt, ...) [YGLog log:[NSString stringWithFormat:(fmt), ##__VA_ARGS__]]

@interface YGLog : NSObject
+ (void)log:(NSString *)msg;
+ (NSString *)logPath;
+ (void)clear;
+ (NSArray<NSString *> *)recentLines;
+ (void)logEnvironment;
@end

#pragma mark - 几何 / 屏幕

/// 当前前台窗口 bounds（point）。iOS 13+ 走 connectedScenes，不依赖 keyWindow。
CGRect  YGScreenBounds(void);
CGSize  YGScreenSize(void);
CGFloat YGScreenScale(void);

/// 是不是本插件自己的窗口（引擎/取窗口时要跳过）
BOOL YGIsOverlayWindow(UIWindow *w);

/// 前台「真实」窗口（已排除悬浮窗与系统 HUD）
UIWindow *YGForegroundWindow(void);

/// window 内 point → 屏幕 point（HID 用全局坐标，UIKit 手势用 window 坐标）
CGPoint YGConvertPointToScreen(CGPoint p, UIWindow *w);

#pragma mark - Swizzle 工具

void YGSwizzleInstance(Class cls, SEL orig, SEL alt);
void YGSwizzleClass(Class cls, SEL orig, SEL alt);

#pragma mark - 配置

@interface YGConfig : NSObject

@property (nonatomic, assign) CGPoint   targetPoint;    ///< 目标点（屏幕 point）
@property (nonatomic, assign) BOOL      hasTarget;      ///< 是否已标记
@property (nonatomic, assign) CGFloat   interval;       ///< 循环间隔（秒），>= 0.02
@property (nonatomic, assign) CGFloat   holdDuration;   ///< 单次按压时长（秒），0.02~0.2
@property (nonatomic, assign) NSInteger backend;        ///< YGInjectBackend
@property (nonatomic, assign) CGPoint   ballCenter;     ///< 悬浮球中心
@property (nonatomic, assign) CGFloat   ballAlpha;
@property (nonatomic, assign) BOOL      showCrosshair;
@property (nonatomic, assign) BOOL      volumeDownStops;
@property (nonatomic, assign) BOOL      ballHidden;
@property (nonatomic, assign) NSInteger tapCount;

+ (instancetype)shared;
- (void)load;
- (void)save;
- (NSString *)configPath;

@end

#pragma mark - 注入后端

typedef NS_ENUM(NSInteger, YGInjectBackend) {
    YGInjectBackendAuto       = 0,
    YGInjectBackendHID        = 1,
    YGInjectBackendSpringHID  = 2,
    YGInjectBackendUITouch    = 3,
    YGInjectBackendGSEvent    = 4,
};

@interface YGInjector : NSObject
+ (instancetype)shared;

- (void)probe;
- (BOOL)tapAtScreenPoint:(CGPoint)pt;
- (void)setBackend:(YGInjectBackend)b;
- (YGInjectBackend)backend;

@property (nonatomic, readonly) BOOL hidAvailable;
@property (nonatomic, readonly) BOOL springHIDAvailable;
@property (nonatomic, readonly) BOOL uiTouchAvailable;
@property (nonatomic, readonly) BOOL gsEventAvailable;
@property (nonatomic, readonly, copy) NSString *activeBackendName;

@end

#pragma mark - 循环引擎

@interface YGTapEngine : NSObject
+ (instancetype)shared;

- (BOOL)isRunning;
- (void)start;
- (void)stop;
- (void)restartIfRunning;

@property (nonatomic, readonly) NSUInteger ticks;
@property (nonatomic, readonly) NSUInteger fails;

@end

#pragma mark - 音量键

@interface YGVolumeButton : NSObject
+ (instancetype)shared;

- (void)installWithHandler:(void (^)(void))handler;
- (void)uninstall;

@property (nonatomic, readonly) BOOL avSystemOK;
@property (nonatomic, readonly) BOOL mediaRemoteOK;   ///< 实为 L3(SpringBoard swizzle) 状态
@property (nonatomic, readonly) BOOL hidKeyboardOK;

@end

#pragma mark - 悬浮 UI

@interface YGOverlayWindow : UIWindow
- (instancetype)initWithWindowScene:(UIWindowScene *)scene;
- (UIView *)ygContentRoot;
- (void)yg_present;
+ (NSInteger)touchableTag;

/// 设置「不准被让行规则吞掉」的面板视图。
///
/// 落点让行是整窗级别的（注入事件和用户手指在 hitTest 里没法区分），
/// 但控制面板必须始终可点 —— 否则运行时正好把面板放在目标点附近，
/// 「停止」按钮就按不动了，只剩音量键一条退路。
/// 面板本来就在占那块屏幕区域，注入的点击落在面板上同样到不了下层 App，
/// 所以把面板排除在让行之外没有任何损失。
@property (nonatomic, weak) UIView *ygPanelView;
@end

#pragma mark - 注入期间的窗口穿透

/// 进入/退出「全窗口穿透」区（可重入计数）。
///
/// 为什么必须有：注入的事件同样要走窗口 hitTest 派发。
/// 在 SpringBoard 前台（桌面）时，我们自己的悬浮窗就在事件链上；
/// 若目标点正好落在准星（44x44，pointInside 还外扩到 64x64）或悬浮球上，
/// 事件会被自己的窗口吃掉 —— 表现就是「坐标明明对，点下去没反应」。
///
/// 计数式而非布尔：注入频率可能高于事件派发延迟，两个 tap 交叠时
/// 布尔会在第一个结束时把标志清掉，第二个就被自己拦住。
///
/// ★ 但这个计数只能覆盖「同步派发」的后端（UITOUCH / SENDEVENT：
///   它们在主线程 dispatch_sync 里就完成 hitTest）。HID 后端的事件交给
///   backboardd，由 SpringBoard 主线程稍后异步处理，此刻计数早已归零。
///   所以 YGOverlayWindow 的 hitTest 里还有一条「按落点判定」的持久规则，
///   两条一起才覆盖全部后端。见 YGOverlayWindow.m 的 ygHitTestPassthrough。
///
/// 任意线程可调用；不加锁（__atomic 内建）。
void YGSetTapPassthrough(BOOL on);

/// 目标点周围的「自动让行」半径（point）。引擎运行时，落在该半径内的事件
/// 一律穿透到下层 App，不管那里是不是我们自己的控件。
extern const CGFloat kYGTapPassthroughRadius;

@interface YGCrosshairView : UIView
@property (nonatomic, assign) CGPoint targetPoint;
@property (nonatomic, assign) BOOL    running;
- (void)updatePosition;
@end

@interface YGBallView : UIView
@property (nonatomic, assign) BOOL running;
@property (nonatomic, copy)   NSString *badge;
@end

@interface YGOverlayController : NSObject
+ (instancetype)shared;
- (void)install;
- (void)uninstall;
- (void)rebindScene;
- (void)refreshCrosshair;
- (void)refreshPanel;
- (void)togglePanel;
/// 有别的窗口（通知横幅 / 来电 / 系统 HUD）跑到悬浮窗上面时，把悬浮窗重新抬高。
/// otherLevel 传对方 windowLevel；本方法只会往上抬，不会降。
- (void)ensureTopmostLevel:(CGFloat)otherLevel;
/// 悬浮窗被系统回收后自愈（Tweak.xm 在 makeKeyAndVisible 时探一次）
- (void)reviveIfNeeded;
@property (nonatomic, readonly) BOOL installed;
@end

#pragma mark - 引导（AutoTapper.xm 实现，Tweak.xm 复用）

@interface YGBootstrap : NSObject
+ (instancetype)shared;
- (void)startWithReason:(NSString *)reason;
- (void)stop;
@property (nonatomic, readonly) BOOL started;
@property (nonatomic, readonly) BOOL isSpringBoard;
@end

#pragma mark - 私有 API 声明（编译期类型安全，运行时仍 respondsToSelector 再调）

@interface UIApplication (YGPrivate)
- (void)_enqueueHIDEvent:(id)event;
- (void)_dispatchTouches:(NSSet *)touches event:(id)event;
@end

@interface UIWindow (YGPrivate)
- (void)_sendTouchesForEvent:(id)event;
@end

#endif /* YG_CORE_H */
