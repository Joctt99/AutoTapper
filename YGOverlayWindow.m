//
//  YGOverlayWindow.m — 全局悬浮窗 + 十字准星 + 悬浮球
//
//  ★ iOS 13+ 的窗口要点（踩过的坑都在这）：
//
//  1) 不要用 [UIApplication sharedApplication].keyWindow —— iOS 13 起 deprecated，
//     多 scene 下经常返回 nil。正确做法是 UIWindow(windowScene:)。
//  2) 窗口必须 attach 到一个 **已连接** 的 UIWindowScene；scene 断开（App 全退、
//     分屏切换）后窗口会从屏幕上消失，所以要监听 UIScene 通知并 rebindScene。
//  3) windowLevel 要高于 UIWindowLevelAlert(=2000)。系统 HUD（音量条、来电横幅）
//     在 Alert 层，我们要盖在它们上面：用 UIWindowLevelAlert + 2000 = 4000。
//     不要用 UIWindowLevelStatusBar + 大数，某些系统组件会按 statusBar 层排序。
//  4) 全屏透明窗口默认会吃掉所有触摸 —— 必须重写 root view 的
//     -hitTest:withEvent:，只有「可交互子视图」范围内才返回自己，其余返回 nil，
//     这样触摸会穿透到下层 App。
//  5) 不要 becomeKeyWindow / makeKeyAndVisible：那会抢走前台 App 的第一响应者，
//     导致输入框失焦、键盘收起。用 hidden = NO 显示即可。
//

#import "YGCore.h"

#import <math.h>   // fabs / sqrt：落点让行判定要用，别指望 UIKit 头间接带上

#pragma mark - 可交互区标记

static const NSInteger kYGTouchableTag = 9401;

@interface YGOverlayRootView : UIView
@end

@implementation YGOverlayRootView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // 自己不可点，只在子视图（悬浮球/面板/准星）范围内拦截
    for (UIView *sub in [self.subviews reverseObjectEnumerator]) {
        if (sub.hidden || sub.alpha < 0.01 || !sub.userInteractionEnabled) continue;
        if (sub.tag != kYGTouchableTag) continue;
        if (!CGRectContainsPoint(sub.frame, point)) continue;

        UIView *hit = [sub hitTest:[self convertPoint:point toView:sub] withEvent:event];
        if (hit) return hit;
    }
    return nil;   // 穿透到下层 App
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *sub in self.subviews) {
        if (sub.tag == kYGTouchableTag && !sub.hidden && CGRectContainsPoint(sub.frame, point)) {
            return YES;
        }
    }
    return NO;
}

@end

#pragma mark - 准星

// YGCrosshairView 的 @interface 在 YGCore.h 里；这里只写实现。

@implementation YGCrosshairView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;

        // 手指点按区比视觉大：44pt 是 HIG 的最小可点尺寸
        CGRect big = self.bounds;
        UIView *hit = [[UIView alloc] initWithFrame:big];
        hit.backgroundColor = [UIColor clearColor];
        hit.userInteractionEnabled = NO;
        [self addSubview:hit];
    }
    return self;
}

/// 打点区放大到 56x56，视觉仍是准星本身
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect r = CGRectInset(self.bounds, -10, -10);
    return CGRectContainsPoint(r, point);
}

- (void)setRunning:(BOOL)running {
    _running = running;
    [self setNeedsDisplay];
}

- (void)setTargetPoint:(CGPoint)targetPoint {
    _targetPoint = targetPoint;
    [self updatePosition];
}

- (void)updatePosition {
    CGFloat s = 44.0;
    self.bounds = CGRectMake(0, 0, s, s);
    self.center = _targetPoint;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGRect b = self.bounds;
    CGFloat cx = CGRectGetMidX(b), cy = CGRectGetMidY(b);
    CGFloat r = 18.0;

    UIColor *color = _running
        ? [UIColor colorWithRed:1.0 green:0.32 blue:0.32 alpha:0.95]
        : [UIColor colorWithRed:0.20 green:0.90 blue:0.70 alpha:0.95];

    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 1.6);

    // 外圆
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - r, cy - r, r * 2, r * 2));

    // 四向短线（缺口准星）
    CGFloat gap = 4.0, len = 10.0;
    CGContextMoveToPoint(ctx, cx, cy - r);
    CGContextAddLineToPoint(ctx, cx, cy - r + len);
    CGContextMoveToPoint(ctx, cx, cy + r);
    CGContextAddLineToPoint(ctx, cx, cy + r - len);
    CGContextMoveToPoint(ctx, cx - r, cy);
    CGContextAddLineToPoint(ctx, cx - r + len, cy);
    CGContextMoveToPoint(ctx, cx + r, cy);
    CGContextAddLineToPoint(ctx, cx + r - len, cy);
    CGContextStrokePath(ctx);
    (void)gap;

    // 中心点（真正落点的位置）
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - 1.6, cy - 1.6, 3.2, 3.2));

    // 坐标标签
    NSString *txt = [NSString stringWithFormat:@"%.0f,%.0f", _targetPoint.x, _targetPoint.y];
    NSDictionary *attrs = @{
        NSFontAttributeName : [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightMedium],
        NSForegroundColorAttributeName : color,
    };
    CGSize ts = [txt sizeWithAttributes:attrs];
    CGRect tr = CGRectMake(cx - ts.width / 2, CGRectGetMaxY(b) - 2, ts.width, ts.height);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.55].CGColor);
    CGContextFillRect(ctx, CGRectInset(tr, -2, 0));
    [txt drawInRect:tr withAttributes:attrs];
}

@end

#pragma mark - 悬浮球

// YGBallView 的 @interface 在 YGCore.h 里；这里只写实现。

@implementation YGBallView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 4;
        self.layer.shadowOffset = CGSizeMake(0, 2);
    }
    return self;
}

- (void)setRunning:(BOOL)running {
    _running = running;
    [self setNeedsDisplay];
}

- (void)setBadge:(NSString *)badge {
    _badge = [badge copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat w = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
    CGRect circle = CGRectMake((CGRectGetWidth(self.bounds) - w) / 2,
                               (CGRectGetHeight(self.bounds) - w) / 2, w, w);

    UIColor *base = _running
        ? [UIColor colorWithRed:0.92 green:0.28 blue:0.28 alpha:0.92]
        : [UIColor colorWithWhite:0.10 alpha:0.85];

    CGContextSetFillColorWithColor(ctx, base.CGColor);
    CGContextFillEllipseInRect(ctx, circle);

    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.55].CGColor);
    CGContextSetLineWidth(ctx, 1.2);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(circle, 0.6, 0.6));

    // 中间画一个「靶心」
    CGFloat cx = CGRectGetMidX(circle), cy = CGRectGetMidY(circle);
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, 1.4);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - 8, cy - 8, 16, 16));
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - 2.4, cy - 2.4, 4.8, 4.8));

    if (_badge.length) {
        NSDictionary *attrs = @{
            NSFontAttributeName : [UIFont monospacedDigitSystemFontOfSize:8 weight:UIFontWeightBold],
            NSForegroundColorAttributeName : [UIColor whiteColor],
        };
        CGSize ts = [_badge sizeWithAttributes:attrs];
        CGRect tr = CGRectMake(cx - ts.width / 2, CGRectGetMaxY(circle) - 12, ts.width, ts.height);
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.6].CGColor);
        CGContextFillRect(ctx, CGRectInset(tr, -2, -0.5));
        [_badge drawInRect:tr withAttributes:attrs];
    }
}

@end

#pragma mark - 注入期间穿透（计数器）

/*
 * 为什么用计数器而不是 BOOL：
 *   引擎队列上一个 tick 结束前就可能来下一个 tick（holdDuration 长 / 间隔短），
 *   布尔标志会被「先结束的那个」提前清成 NO，导致后一个 tap 的 down/up
 *   落在穿透关闭期间 → 被自己的准星吃掉。
 *
 * 为什么用 OSAtomic 而不是 @synchronized / dispatch_sync：
 *   hitTest: 在主线程，注入在引擎队列 —— 一旦在 hitTest 里等锁，
 *   主线程会跟着卡。这里的读写必须是 lock-free 的。
 */

static volatile int32_t gYGTapPassthrough = 0;

/// 目标点周围的自动让行半径。准星视觉 44pt、pointInside 外扩 10pt（共 64pt），
/// 取 40pt 半覆盖已经能保证「目标点 1pt 误差内一定让行」，又不会把
/// 恰好路过该区域的用户手指也一起吞掉（用户手指的事件不走注入路径，
/// 但同一坐标区被让行时用户仍然能正常操作下层 App，代价可接受）。
const CGFloat kYGTapPassthroughRadius = 40.0;

void YGSetTapPassthrough(BOOL on) {
    if (on) {
        __atomic_fetch_add(&gYGTapPassthrough, 1, __ATOMIC_SEQ_CST);
    } else {
        // 不要减到负数：多余的 off 不能让计数器翻到 65535 而永久穿透
        int32_t prev = __atomic_fetch_sub(&gYGTapPassthrough, 1, __ATOMIC_SEQ_CST);
        if (prev <= 0) __atomic_store_n(&gYGTapPassthrough, 0, __ATOMIC_SEQ_CST);
    }
}

static inline BOOL YGTapPassthroughActive(void) {
    return __atomic_load_n(&gYGTapPassthrough, __ATOMIC_SEQ_CST) > 0;
}

/*
 * 按落点判定的持久让行规则。
 *
 * 为什么需要（HID 后端的时序）：
 *   HID 路径是 IOHIDEventSystemClientDispatchEvent → backboardd → SpringBoard
 *   主线程派发 → hitTest。dispatch 调用是同步的，但**事件处理不是**。
 *   tapAtScreenPoint 里的 YGSetTapPassthrough(YES/NO) 在内核那一跳就走完了，
 *   hitTest 真正跑来时计数器已经归零 —— 于是「点在自己准星上」依然被吃。
 *
 *   所以额外加一条不依赖计时的规则：只要引擎在跑，且触摸点落在目标点
 *   半径内，本窗口就一律让行。引擎不跑时完全恢复正常交互（可以拖准星）。
 */
static inline BOOL YGPointInsideTapZone(CGPoint pointInWindow) {
    YGConfig *cfg = YGConfig.shared;
    if (!cfg.hasTarget) return NO;
    if (![YGTapEngine shared].isRunning) return NO;

    CGPoint t = cfg.targetPoint;
    CGFloat dx = pointInWindow.x - t.x;
    CGFloat dy = pointInWindow.y - t.y;
    CGFloat r  = kYGTapPassthroughRadius;
    if (dx * dx + dy * dy > r * r) return NO;

    /*
     * 限流打日志：hitTest 每次触摸都会跑，引擎 20Hz 时一秒能刷 20 条，
     * 把 AutoTapper.log 写爆（而且每条都要 open/write/close 文件）。
     * 只在点位变化超过 1pt 或距上次超过 2 秒时记一行。
     */
    static CGPoint lastPt = { -1000, -1000 };
    static NSTimeInterval lastT = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL moved = (fabs(lastPt.x - pointInWindow.x) > 1.0 ||
                  fabs(lastPt.y - pointInWindow.y) > 1.0);
    if (moved || now - lastT > 2.0) {
        lastPt = pointInWindow;
        lastT  = now;
        YGLOG(@"hitTest 让行：点 (%.1f,%.1f) 落在目标点 (%.1f,%.1f) 的 %.0fpt 内",
              pointInWindow.x, pointInWindow.y, t.x, t.y, r);
    }
    return YES;
}

#pragma mark - 窗口

@implementation YGOverlayWindow

- (instancetype)initWithWindowScene:(UIWindowScene *)scene {
    if (scene) {
        self = [super initWithWindowScene:scene];
    } else {
        // ★ iOS 12 及以下 / scene 尚未就绪时的兜底。
        // 不碰 UIScreen.mainScreen（iOS 26 注入场景实测会信号级崩溃），用固定值。
        self = [super initWithFrame:CGRectMake(0, 0, 390, 844)];
    }
    if (self) {
        // 高于 UIWindowLevelAlert(2000)：盖住音量 HUD、来电横幅、系统 toast
        self.windowLevel = UIWindowLevelAlert + 2000;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.hidden = NO;
        self.userInteractionEnabled = YES;
        // 关键：不要 makeKeyWindow / becomeKeyWindow
        self.rootViewController = ({
            UIViewController *vc = [UIViewController new];
            vc.view = [[YGOverlayRootView alloc] initWithFrame:self.bounds];
            vc.view.backgroundColor = [UIColor clearColor];
            vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                       UIViewAutoresizingFlexibleHeight;
            vc;
        });
    }
    return self;
}

/// 让窗口真的显示（不抢 key）
- (void)yg_present {
    self.hidden = NO;
    if (@available(iOS 13.0, *)) {
        // windowScene 为空时会自动 fallback 到旧的 windows 机制
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    /*
     * 两道闸，缺一不可：
     *   1) 计数器：覆盖同步派发的后端（UITOUCH / SENDEVENT），
     *      以及 down/up 之间的「按下态」不被自己打断；
     *   2) 落点判定：覆盖 HID 后端（异步派发，计数器早已归零）。
     *
     * 两道闸之前先放行面板：面板是唯一的手动「停止」入口，任何时候都得能按。
     */
    UIView *panel = self.ygPanelView;
    if (panel && !panel.hidden && panel.alpha > 0.01) {
        CGPoint p = [panel convertPoint:point fromView:self];
        if ([panel pointInside:p withEvent:event]) {
            UIView *hit = [panel hitTest:p withEvent:event];
            if (hit) return hit;
        }
    }

    if (YGTapPassthroughActive()) return nil;
    if (YGPointInsideTapZone(point)) return nil;

    UIView *hit = [super hitTest:point withEvent:event];
    // 根视图返回 nil 时 hit 会是 window 自己 —— 这种情况必须返回 nil 来穿透
    if (hit == self) return nil;
    return hit;
}

/// 点位没变时不要重复打日志：hitTest 每次触摸都会执行，
/// 引擎 20Hz 跑起来一秒能刷 20 条，会把日志文件写爆。
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (YGTapPassthroughActive()) return NO;
    if (YGPointInsideTapZone(point)) return NO;
    return [super pointInside:point withEvent:event];
}

+ (NSInteger)touchableTag { return kYGTouchableTag; }

- (UIView *)ygContentRoot { return self.rootViewController.view; }

@end
