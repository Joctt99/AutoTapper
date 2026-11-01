//
//  Tweak.xm — 系统级 hook 层（与 AutoTapper.xm 分工不同）
//
//  AutoTapper.xm  -> 「什么时候把自己装起来」（生命周期 / %ctor / SpringBoard 启动）
//  Tweak.xm       -> 「装起来之后，拦截哪些系统行为来保证体验正确」
//
//  这个文件只做三类事：
//    A. 窗口层级守护
//       通知横幅、来电界面、系统 HUD 会把 windowLevel 抬到 Alert 附近；
//       我们的悬浮窗固定在 Alert+2000，但有些系统窗口层级更高（如 3000+）。
//       在这些窗口 makeKeyAndVisible 的时候把自己的层级再抬上去，
//       否则表现是「点着点着悬浮球被横幅盖住，点不到了」。
//
//    B. SpringBoard 侧「回到桌面 / App 切换」后的状态刷新
//       前台 App 变化时目标点坐标可能已不在可视区（横竖屏切换 / 分屏），
//       重算并夹回屏幕内；同时刷新准星显示。
//
//    C. 安全阀
//       SpringBoard 进入后台 / 锁屏 / 设备锁定 时**强制停止循环点击**，
//       避免锁屏后手指还在某处不停点（会误触、掉电、甚至误买）。
//
//  A 组用 %group + %hook；B 组刻意改成运行时探测的 C 函数（见该节说明：
//  私有方法名跨版本会变，%hook 不存在的名字会变成永不触发的死代码）；
//  C 组用 %group + %hook。全部在 %ctor 里按进程显式装载，
//  这样在 App 进程注入时不会去碰 SB* 私有类（那里根本没有）。
//

#import "YGCore.h"
#import "YGPrivateAPI.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>

// 侧载（证书签名）场景没有 CydiaSubstrate，用 Logos internal 生成器：
// 生成的 hook 直接走 Objective-C runtime，产物不依赖任何注入框架。
%config(generator=internal)

#pragma mark - A. 窗口层级守护

%group WindowGuard

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;

    // 只关心「比我们的窗口层级高」的系统窗口。
    // 自己的 YGOverlayWindow 永远不 makeKeyAndVisible（会抢第一响应者），
    // 所以这里遇到的一定是别人的窗口，不需要排除自己。
    CGFloat lvl = self.windowLevel;
    if (lvl >= UIWindowLevelAlert) {
        // dispatch_async 而不是直接调：makeKeyAndVisible 期间改别的窗口层级
        // 会让 CA 在同一个事务里提交两次 window 顺序，偶发闪烁。
        dispatch_async(dispatch_get_main_queue(), ^{
            [[YGOverlayController shared] ensureTopmostLevel:lvl];
        });
    }
}

%end

%end

#pragma mark - B. 前台 App 切换 / 方向变化

/*
 * 注意：这一段**故意不用 %group / %hook**，全部是运行时的普通 C 函数。
 * 原因见下面说明。%ctor 里直接调用 YGInstallFrontAppHooks()。
 */

/*
 * 为什么这里必须运行时探测，不能直接 %hook：
 *   「前台 App 变了」这个动作在 SpringBoard 里的入口方法名换过很多次：
 *       iOS 12/13: -_setActiveApplication:
 *       iOS 14/15: -_setActiveApplication:  (仍在)
 *       iOS 16/17: 改走 SBWorkspace / SBApplicationController，上面那个不一定有
 *   而 %hook 一个**不存在**的方法时，Logos 会用 class_addMethod 把它加上去，
 *   系统永远不会调用它 → 「看起来装好了，其实死代码」。
 *   更糟的是如果方法存在但签名不同，%orig 传错参数会直接崩。
 *
 *   所以：逐个候选做 respondsToSelector + 签名校验，命中哪条挂哪条；
 *   全都不命中就退回通知观察（一定能用，只是略慢）。
 */

/// 一条「前台 App 变了」的公共处理
static void YGHandleFrontAppChanged(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        YGOverlayController *oc = [YGOverlayController shared];
        [oc rebindScene];
        [oc refreshCrosshair];
        [oc refreshPanel];

        // 目标点如果跑到屏幕外（横竖屏切换导致尺寸变化），夹回可视区
        YGConfig *cfg = YGConfig.shared;
        if (cfg.hasTarget) {
            CGSize sz = YGScreenSize();
            CGPoint p = cfg.targetPoint;
            CGFloat nx = MIN(MAX(p.x, 1.0), sz.width  - 1.0);
            CGFloat ny = MIN(MAX(p.y, 1.0), sz.height - 1.0);
            if (fabs(nx - p.x) > 0.5 || fabs(ny - p.y) > 0.5) {
                cfg.targetPoint = CGPointMake(nx, ny);
                [cfg save];
                YGLOG(@"目标点被夹回屏幕内 (%.1f,%.1f) → (%.1f,%.1f)",
                      p.x, p.y, nx, ny);
                [oc refreshCrosshair];
            }
        }
    });
}

/// 保存每个候选的原实现（都是 v@:@ 形式）
static void (*gOrigSetActiveApp)(id, SEL, id) = NULL;
static void (*gOrigSetFrontDisplayApp)(id, SEL, id) = NULL;

static void YGSetActiveAppHook(id self, SEL _cmd, id app) {
    if (gOrigSetActiveApp) gOrigSetActiveApp(self, _cmd, app);
    YGHandleFrontAppChanged();
}

static void YGSetFrontDisplayAppHook(id self, SEL _cmd, id app) {
    if (gOrigSetFrontDisplayApp) gOrigSetFrontDisplayApp(self, _cmd, app);
    YGHandleFrontAppChanged();
}

/// 挂一条 v@:@ 签名的方法；返回是否成功
static BOOL YGHookObjectArg(Class cls, NSString *selName, IMP hook, void **origSlot) {
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    const char *enc = method_getTypeEncoding(m);
    // 只要 «返回值 v + 两个隐藏参数 @: + 一个 object@» 的前缀对上就安全
    if (!enc || strncmp(enc, "v@:@", 4) != 0) {
        YGLOG(@"%@ 签名不符 (%s)，跳过", selName, enc ?: "?");
        return NO;
    }
    *origSlot = (void *)method_getImplementation(m);
    method_setImplementation(m, hook);
    YGLOG(@"前台 App 变化 hook 已挂: SB %@", selName);
    return YES;
}

static void YGInstallFrontAppHooks(void) {
    Class sb = NSClassFromString(@"SpringBoard");
    if (!sb) return;

    if (YGHookObjectArg(sb, @"_setActiveApplication:",
                        (IMP)YGSetActiveAppHook, (void **)&gOrigSetActiveApp)) return;

    if (YGHookObjectArg(sb, @"_setFrontDisplayApp:",
                        (IMP)YGSetFrontDisplayAppHook,
                        (void **)&gOrigSetFrontDisplayApp)) return;

    /* 两个候选都没命中 → 退回通知观察，行为一致只是延迟略大 */
    YGLOG(@"SpringBoard 无 _setActiveApplication: / _setFrontDisplayApp:，"
          @"前台切换改用通知观察");
    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        YGHandleFrontAppChanged();
    }];
}

#pragma mark - C. 锁屏 / 后台安全阀

%group SafetyValve

/*
 * 为什么不用 %hook SpringBoard 的某个「锁屏」私有方法：
 *   锁屏相关方法名在 iOS 13→17 之间改过三次（_lockScreenWakeStateChanged /
 *   _lockStateChanged / lockUIFromSource:withOptions:），%hook 一个不存在的
 *   方法时 Logos 会用 class_addMethod 把 hook 装上去 —— 而系统根本不会调用它，
 *   于是「看起来装好了但永远不触发」，比不装更危险。
 *
 * 所以这里只用两条**确定存在**的信号：
 *   1) SpringBoard -applicationDidEnterBackground:
 *   2) 系统级 UIScreenDidConnect / UIApplicationDidEnterBackground 通知
 * 再额外用运行时探测去挂 SBLockScreenManager（存在才挂）。
 */

%hook SpringBoard

- (void)applicationDidEnterBackground:(id)application {
    %orig;

    YGTapEngine *eng = [YGTapEngine shared];
    if (eng.isRunning) {
        YGLOG(@"SpringBoard 进后台 → 强制停止点击");
        [eng stop];
        [[YGOverlayController shared] refreshCrosshair];
        [[YGOverlayController shared] refreshPanel];
    }
}

%end

%end

#pragma mark - C2. SBLockScreenManager（运行时探测，存在才挂）

/*
 * SBLockScreenManager -lockUIFromSource:(long long)src withOptions:(id)opts
 *   iOS 13 ~ 17 一直有这个方法（锁屏真正发生的入口）。
 * 用运行时探测挂，签名不匹配就跳过 —— 不会破坏系统。
 */
static void (*gOrigLockUI)(id, SEL, long long, id) = NULL;

static void YGLockUIHook(id self, SEL _cmd, long long source, id options) {
    YGTapEngine *eng = [YGTapEngine shared];
    if (eng.isRunning) {
        YGLOG(@"锁屏触发 → 强制停止点击");
        [eng stop];
        [[YGOverlayController shared] refreshCrosshair];
        [[YGOverlayController shared] refreshPanel];
    }
    if (gOrigLockUI) gOrigLockUI(self, _cmd, source, options);
}

static void YGInstallLockScreenHook(void) {
    Class cls = NSClassFromString(@"SBLockScreenManager");
    if (!cls) {
        YGLOG(@"SBLockScreenManager 不在，锁屏安全阀只用后台信号");
        return;
    }
    SEL sel = NSSelectorFromString(@"lockUIFromSource:withOptions:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        YGLOG(@"lockUIFromSource:withOptions: 不在，跳过");
        return;
    }
    // 校验签名：必须是 v@:q@ （void, self, _cmd, long long, object）
    const char *enc = method_getTypeEncoding(m);
    if (enc && strncmp(enc, "v@:q@", 5) != 0) {
        YGLOG(@"lockUIFromSource: 签名不符 (%s)，跳过", enc ?: "?");
        return;
    }
    gOrigLockUI = (void (*)(id, SEL, long long, id))method_getImplementation(m);
    method_setImplementation(m, (IMP)YGLockUIHook);
    YGLOG(@"锁屏安全阀已挂 (SBLockScreenManager)");
}

#pragma mark - 安装

%ctor {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        BOOL isSB = [bid isEqualToString:@"com.apple.springboard"];

        // A 组在所有进程都装：任何进程里都可能被别的窗口盖住
        %init(WindowGuard);

        if (isSB) {
            // C 组是真正的 %hook，用 %init 装载
            %init(SafetyValve);
            // B 组是运行时探测，直接调用（内部自带「全不命中→退回通知」逻辑）
            YGInstallFrontAppHooks();
            YGInstallLockScreenHook();
            YGLOG(@"Tweak.xm: SpringBoard 侧 hook 已装载");
        } else {
            YGLOG(@"Tweak.xm: %@ 进程只装 WindowGuard", bid);
        }
    }
}
