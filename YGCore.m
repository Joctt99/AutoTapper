//
//  YGCore.m — 日志 / 屏幕几何 / 场景窗口 / swizzle 工具
//

#import "YGCore.h"

#import <math.h>
#import <string.h>

#pragma mark - 日志

NSString *const YGLogDidAppendNotification      = @"YGLogDidAppendNotification";
NSString *const YGTapEngineDidStopNotification  = @"YGTapEngineDidStopNotification";
NSString *const YGTapEngineDidFailStartNotification = @"YGTapEngineDidFailStartNotification";

static const NSUInteger kYGBufferLines = 500;
static NSString *gLogPath = nil;
static NSLock   *gLogLock = nil;
static NSMutableArray<NSString *> *gLines = nil;

@implementation YGLog

+ (void)initialize {
    if (self != [YGLog class]) return;
    gLogLock = [NSLock new];
    gLines   = [NSMutableArray array];

    // rootless 下 SpringBoard 的 HOME 是 /var/mobile，Documents 可写
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    gLogPath = [dir stringByAppendingPathComponent:@"AutoTapper.log"];
}

+ (NSString *)logPath { return gLogPath; }

+ (void)log:(NSString *)msg {
    if (msg.length == 0) return;
    NSLog(@"[AutoTapper] %@", msg);

    static NSDateFormatter *df = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });

    NSString *line = [NSString stringWithFormat:@"%@ %@",
                      [df stringFromDate:[NSDate date]], msg];

    [gLogLock lock];
    [gLines addObject:line];
    if (gLines.count > kYGBufferLines) {
        [gLines removeObjectsInRange:NSMakeRange(0, gLines.count - kYGBufferLines)];
    }
    // 日志轮转：超过阈值自动归档为 AutoTapper.log.1，避免文件无限膨胀
    static const unsigned long long kYGRotateBytes = 256 * 1024;
    NSDictionary *attrs = [[NSFileManager defaultManager]
                             attributesOfItemAtPath:gLogPath error:NULL];
    if (attrs && [attrs fileSize] >= kYGRotateBytes) {
        NSString *oldPath = [gLogPath stringByAppendingString:@".1"];
        [[NSFileManager defaultManager] removeItemAtPath:oldPath error:NULL];
        [[NSFileManager defaultManager] moveItemAtPath:gLogPath toPath:oldPath error:NULL];
        NSLog(@"[AutoTapper] 日志已轮转 -> AutoTapper.log.1");
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!fh) {
        [[line stringByAppendingString:@"\n"]
            writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[[line stringByAppendingString:@"\n"]
                              dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (__unused NSException *e) {}
    }
    [gLogLock unlock];

    // 同线程同步 post：面板观察者在主线程，日志本身也基本都在主线程产生
    [[NSNotificationCenter defaultCenter] postNotificationName:YGLogDidAppendNotification
                                                        object:line];
}

+ (NSArray<NSString *> *)recentLines {
    [gLogLock lock];
    NSArray *copy = [gLines copy];
    [gLogLock unlock];
    return copy;
}

+ (void)clear {
    [gLogLock lock];
    [gLines removeAllObjects];
    [[NSFileManager defaultManager] removeItemAtPath:gLogPath error:NULL];
    [gLogLock unlock];
}

/// 启动环境摘要：日志路径 / 注入进程 / 后端可用矩阵，一次打印便于排查
+ (void)logEnvironment {
    YGLOG(@"==== environment summary ====");
    YGLOG(@"log file: %@", gLogPath ?: @"?");
    YGLOG(@"home: %@", NSHomeDirectory());
    YGLOG(@"bundle id: %@", [NSBundle mainBundle].bundleIdentifier ?: @"?");
    YGInjector *inj = [YGInjector shared];
    YGLOG(@"backend availability: HID=%d SPRINGHID=%d UITOUCH=%d GSEVENT=%d",
          inj.hidAvailable, inj.springHIDAvailable, inj.uiTouchAvailable,
          inj.gsEventAvailable);
    YGLOG(@"active backend: %@", inj.activeBackendName ?: @"(none)");
    YGLOG(@"==== end environment summary ====");
}

@end

#pragma mark - 屏幕 / 场景

/// UIWindowScene 的安全取值：优先前台 active，其次任意 connectedScene。
/// ★ iOS 13+ 不许再用 [UIApplication sharedApplication].keyWindow，
///   它在多 scene / 分屏 / 画中画下返回 nil 或错的 window。
static UIWindowScene *YGActiveWindowScene(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return nil;

    NSSet<UIScene *> *scenes = app.connectedScenes;
    if (![scenes isKindOfClass:[NSSet class]] || scenes.count == 0) return nil;

    UIWindowScene *best = nil;
    NSInteger bestScore = -1;

    for (UIScene *s in scenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;

        NSInteger score = 0;
        if (ws.activationState == UISceneActivationStateForegroundActive) score += 100;
        else if (ws.activationState == UISceneActivationStateForegroundInactive) score += 50;
        else if (ws.activationState == UISceneActivationStateBackground) score += 1;

        // 主屏优先（external display / CarPlay 也会是 UIWindowScene）
        if ([ws.screen isEqual:UIScreen.mainScreen]) score += 20;

        if (score > bestScore) { bestScore = score; best = ws; }
    }
    return best;
}

CGRect YGScreenBounds(void) {
    // UIScreen.bounds 在 iOS 8+ 就是「当前界面方向」下的逻辑 point bounds，
    // 比 deprecated 的 [UIScreen mainScreen].applicationFrame 更适合注入场景。
    UIWindowScene *ws = YGActiveWindowScene();
    if (ws) {
        UIWindow *w = YGForegroundWindow();
        if (w && w.bounds.size.width > 0 && w.bounds.size.height > 0) return w.bounds;
        if (ws.coordinateSpace.bounds.size.width > 0) return ws.coordinateSpace.bounds;
    }
    CGRect b = UIScreen.mainScreen.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) {
        // 极端情况下（注入过早，UIScreen 还没就绪）用 iPhone 13 Pro 的物理尺寸兜底
        b = CGRectMake(0, 0, 390, 844);
    }
    return b;
}

CGSize  YGScreenSize(void)  { return YGScreenBounds().size; }
CGFloat YGScreenScale(void) {
    CGFloat s = UIScreen.mainScreen.scale;
    return s > 0 ? s : 3.0;
}

BOOL YGIsOverlayWindow(UIWindow *w) {
    if (!w) return NO;
    // 类名判断最稳：即使 overlay 还没初始化，也不会把系统 HUD 当成自己
    Class cls = [w class];
    while (cls) {
        NSString *n = NSStringFromClass(cls);
        if ([n isEqualToString:@"YGOverlayWindow"] ||
            [n isEqualToString:@"YGPanelWindow"]) return YES;
        cls = class_getSuperclass(cls);
    }
    return NO;
}

UIWindow *YGForegroundWindow(void) {
    UIWindowScene *ws = YGActiveWindowScene();
    if (ws) {
        // windows 顺序是从「最底」到「最上」，倒序取第一个非本插件窗口
        NSArray<UIWindow *> *wins = ws.windows;
        for (NSInteger i = (NSInteger)wins.count - 1; i >= 0; i--) {
            UIWindow *w = wins[i];
            if (w.hidden || w.alpha < 0.01) continue;
            if (YGIsOverlayWindow(w)) continue;
            if (w.windowLevel >= UIWindowLevelStatusBar) continue; // 系统 HUD
            if (w.bounds.size.width <= 0) continue;
            return w;
        }
    }
    // 无 scene 的极老路径（iOS 12 及以下 / 部分注入上下文）
    UIApplication *app = UIApplication.sharedApplication;
    for (UIWindow *w in app.windows) {
        if (YGIsOverlayWindow(w)) continue;
        if (w.hidden) continue;
        return w;
    }
    return nil;
}

CGPoint YGConvertPointToScreen(CGPoint p, UIWindow *w) {
    if (!w) return p;
    // window → screen 的坐标换算：用 UIWindow 的 convertPoint:toWindow:nil
    // 在 iOS 13+ 下等价于转换到「该窗口所在 scene 的坐标空间」，
    // 对单一全屏 scene 就是屏幕 point 坐标。
    UIWindow *other = nil;
    CGPoint s = [w convertPoint:p toWindow:other];
    // 少数情况下（注入上下文没有 scene）转换会失败返回原值，此时直接用 p
    if (isnan(s.x) || isnan(s.y)) return p;
    return s;
}

#pragma mark - Swizzle

void YGSwizzleInstance(Class cls, SEL orig, SEL alt) {
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, alt);
    if (!m1 || !m2) {
        YGLOG(@"swizzle FAILED %@ %@ (m1=%p m2=%p)",
              NSStringFromClass(cls), NSStringFromSelector(orig), m1, m2);
        return;
    }
    BOOL added = class_addMethod(cls, orig,
                                 method_getImplementation(m2),
                                 method_getTypeEncoding(m2));
    if (added) {
        class_replaceMethod(cls, alt,
                            method_getImplementation(m1),
                            method_getTypeEncoding(m1));
    } else {
        method_exchangeImplementations(m1, m2);
    }
}

void YGSwizzleClass(Class cls, SEL orig, SEL alt) {
    Class meta = object_getClass(cls);
    if (!meta) return;
    YGSwizzleInstance(meta, orig, alt);
}
