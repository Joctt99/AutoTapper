//
//  AutoTapper.xm — 插件入口（Logos）
//
//  这个文件负责「什么时候把插件装起来」，不负责具体点击逻辑：
//    * SpringBoard 进程：等 applicationDidFinishLaunching 之后再装悬浮窗，
//      避免和系统启动期的窗口创建打架（此时 connectedScenes 还是空的）。
//    * 普通 App 进程（如果 filter plist 里加了这个 App）：立刻装，只用进程内后端。
//
//  %ctor 太早：SpringBoard 此时 UIKit 还没起来，UIScreen 可能返回 0x0，
//  所以我们只在 %ctor 里做「符号探测 + 配置加载」，UI 留给 didFinishLaunching。
//

#import "YGCore.h"
#import "YGPrivateAPI.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>

// 侧载（证书签名）场景没有 CydiaSubstrate，用 Logos internal 生成器：
// 生成的 hook 直接走 Objective-C runtime，产物不依赖任何注入框架。
%config(generator=internal)

#pragma mark - 前向声明

// 定义在文件末尾（%hook 之后），这里先声明，避免 C 的「先声明后使用」报错
static void YGInstallOrientationHook(void);

#pragma mark - 引导

// 注意：YGBootstrap 的 @interface 声明在 YGCore.h 里，这里不要再声明一遍，
// 否则 clang 报 "duplicate interface definition for class 'YGBootstrap'"。

@implementation YGBootstrap

+ (instancetype)shared {
    static YGBootstrap *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [YGBootstrap new]; });
    return s;
}

- (BOOL)isSpringBoard {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    return [bid isEqualToString:@"com.apple.springboard"];
}

- (void)startWithReason:(NSString *)reason {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startWithReason:reason];
        });
        return;
    }
    if (_started) return;
    _started = YES;

    YGLOG(@"==== AutoTapper bootstrap: %@ (springboard=%d) ====",
          reason, [self isSpringBoard]);
    YGLOG(@"device=%@ system=%@", [UIDevice currentDevice].model,
          [UIDevice currentDevice].systemVersion);

    // 1) 私有符号 / 后端探测（纯 dlsym，不碰 UIKit，绝对安全）
    [[YGInjector shared] probe];
    // 启动环境摘要：日志路径 + 后端可用矩阵，一眼定位问题
    [YGLog logEnvironment];

    // 2) 屏幕几何（防御式函数，异常自动回退，不会崩）
    CGRect sb = YGScreenBounds();
    CGFloat ss = YGScreenScale();
    YGLOG(@"screen=%@ scale=%.1f", NSStringFromCGRect(sb), ss);

    // 3) 悬浮 UI
    [[YGOverlayController shared] install];

    // 3) 音量减键（仅 SpringBoard 有意义：App 进程里收不到系统级按键）
    if ([self isSpringBoard]) {
        [[YGVolumeButton shared] installWithHandler:^{
            YGConfig *cfg = YGConfig.shared;
            if (!cfg.volumeDownStops) return;
            YGTapEngine *eng = [YGTapEngine shared];
            if (eng.isRunning) {
                YGLOG(@"音量减命中 → 停止");
                [eng stop];
                [[YGOverlayController shared] refreshCrosshair];
                [[YGOverlayController shared] refreshPanel];
            }
        }];
    }

    // 4) 屏幕旋转 / 尺寸变化：准星与悬浮球要重新夹回可视区
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onScreenChanged:)
                                                 name:UIScreenDidConnectNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onAppDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)stop {
    if (!_started) return;
    _started = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[YGOverlayController shared] uninstall];
    [[YGVolumeButton shared] uninstall];
}

- (void)onScreenChanged:(NSNotification *)n {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [[YGOverlayController shared] rebindScene];
        [[YGOverlayController shared] refreshCrosshair];
    });
}

- (void)onAppDidBecomeActive:(NSNotification *)n {
    // 从后台回来 / App 切换：scene 可能变了，窗口要重新绑，否则悬浮球会消失
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [[YGOverlayController shared] rebindScene];
        [[YGOverlayController shared] refreshCrosshair];
        [[YGOverlayController shared] refreshPanel];
    });
}

@end

#pragma mark - 构造：只做轻量准备

%ctor {
    @autoreleasepool {
        // 诊断锚点：NSLog 走系统日志（os_log），不需要沙盒文件权限。
        // 若 dyld 加载失败，这条不会出现 → 问题在签名/注入路径；
        // 若出现后仍闪退 → 问题在执行期，可据此定位。
        NSLog(@"[AutoTapper] ctor begin");
        // 配置先读出来（后续 UI 直接用）
        [YGConfig shared];
        // 符号探测（纯 dlsym，安全）
        YGHIDResolve();

        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        YGLOG(@"tweak loaded into %@", bid.length ? bid : @"?");

        // 非 SpringBoard 进程（plist 里额外加了 App 时才会走到）：
        // 等 UIApplicationDidFinishLaunching 后再装，避开 App 启动早期
        // UIKit 场景未就绪（iOS 26 上此时枚举 connectedScenes 会崩）。
        // 3 秒兜底：万一通知已错过，强制启动。
        if (![bid isEqualToString:@"com.apple.springboard"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                static dispatch_once_t once;
                dispatch_once(&once, ^{
                    __block id obs = nil;
                    void (^start)(void) = ^{
                        [[NSNotificationCenter defaultCenter] removeObserver:obs];
                        NSString *bid2 = [NSBundle mainBundle].bundleIdentifier ?: @"?";
                        [[YGBootstrap shared] startWithReason:
                            [NSString stringWithFormat:@"app %@ (didFinishLaunching)", bid2]];
                    };
                    obs = [[NSNotificationCenter defaultCenter]
                        addObserverForName:UIApplicationDidFinishLaunchingNotification
                                    object:nil queue:[NSOperationQueue mainQueue]
                                usingBlock:^(NSNotification *n) { start(); }];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(3 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (![YGBootstrap shared].started) start();
                    });
                });
            });
        }
    }
}

#pragma mark - SpringBoard 生命周期

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // SpringBoard 启动完成 → scene 已就绪，可以建窗口了
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [[YGBootstrap shared] startWithReason:@"SpringBoard didFinishLaunching"];
        // 方向变化钩子在 didFinishLaunching 之后才挂：
        // 此时 SpringBoard 的类方法表已完整，探测才准
        YGInstallOrientationHook();
    });
}

- (void)applicationDidBecomeActive:(id)application {
    %orig;
    // 每次回前台都检查一下：如果窗口被系统回收（如内存警告），重建
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        YGBootstrap *bs = [YGBootstrap shared];
        if (!bs.started) {
            [bs startWithReason:@"SpringBoard didBecomeActive"];
        } else {
            [[YGOverlayController shared] rebindScene];
            [[YGOverlayController shared] refreshCrosshair];
        }
    });
}

%end

#pragma mark - 屏幕方向变化（SpringBoard 侧，运行时探测）

/*
 * 为什么不用 %hook SpringBoard 的 -_frontMostAppInterfaceOrientationChanged:：
 *   这个私有方法在 iOS 14 之后不一定存在（方向管理改到 FBSOrientationObserver /
 *   SBSceneManager 去了）。%hook 一个不存在的方法时 Logos 会用 class_addMethod
 *   装上去，系统永远不调用它 —— 钩子看起来装了，其实是死代码。
 *   签名如果是 v@:q（long long），和 v@:@ 传错还会有别的风险。
 *
 * 所以改成运行时探测：存在才挂，签名对才挂；都不行就退回
 *   UIApplicationDidBecomeActiveNotification + UIDeviceOrientationDidChangeNotification
 * 这两个一定可用（只是延迟略大）。
 */
static void (*gOrigOrientationChanged)(id, SEL, long long) = NULL;

static void YGOrientationChangedHook(id self, SEL _cmd, long long orientation) {
    if (gOrigOrientationChanged) gOrigOrientationChanged(self, _cmd, orientation);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [[YGOverlayController shared] refreshCrosshair];
        [[YGOverlayController shared] refreshPanel];
    });
}

static void YGInstallOrientationHook(void) {
    Class sb = NSClassFromString(@"SpringBoard");
    SEL sel = NSSelectorFromString(@"_frontMostAppInterfaceOrientationChanged:");
    Method m = sb ? class_getInstanceMethod(sb, sel) : NULL;

    if (m) {
        const char *enc = method_getTypeEncoding(m);
        if (enc && strncmp(enc, "v@:q", 4) == 0) {
            gOrigOrientationChanged =
                (void (*)(id, SEL, long long))method_getImplementation(m);
            method_setImplementation(m, (IMP)YGOrientationChangedHook);
            YGLOG(@"方向变化 hook 已挂 (SB _frontMostAppInterfaceOrientationChanged:)");
            return;
        }
        YGLOG(@"方向方法签名不符 (%s)，退回通知", enc ?: "?");
    }

    /* 兜底：设备方向 + 前台激活两条通知，一定能收到 */
    YGLOG(@"方向变化改用通知观察");
    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"UIDeviceOrientationDidChangeNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            [[YGOverlayController shared] refreshCrosshair];
            [[YGOverlayController shared] refreshPanel];
        });
    }];
}

