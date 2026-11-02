//
//  WJTapCore.m — 连点器核心实现
//
//  还原自 libWJHook（arm64）反编译：
//   - setupUI：红色圆形攻击按钮挂 keyWindow，可拖拽，三种攻击模式
//   - createDotButtonsWithRadius:…：围绕攻击按钮的彩色圆形多点，可拖，点按即连点
//   - 连点引擎：NSTimer 按 clickInterval 触发 scheduleClicks，逐点入 NSOperationQueue
//     （随机 0~40ms 微延迟 + 主线程派发 simulateTapAtPoint）
//   - simulateTapAtPoint:：keyWindow hitTest → UITouch KVC 构造 →
//     UITouchesEvent（私有类，respondsToSelector 兜底）→ 直接派发 touchesBegan/Ended；
//     命中 UIControl 则 sendActionsForControlEvents:UIControlEventTouchUpInside
//   - 设置面板（UIScrollView 挂 keyWindow）：间隔/点数/点径/按钮大小/透明度/模式/隐藏/保存
//   - 持久化：NSUserDefaults + Documents 位置 plist
//   - 日志：Documents/AutoTapper.log（沿用既有轮转 256KB 方案）+ build 标记
//
//  已剥离：验证、授权码、支付、到期检查、截图上报、远程加载、socket、符号重绑定。
//  进程内事件派发不依赖越狱，证书签名侧载 App 内即可工作。
//

#import "WJTapCore.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <unistd.h>

#pragma mark - 日志

#define WJLOG(fmt, ...) [WJTapLog write:[NSString stringWithFormat:fmt, ##__VA_ARGS__]]

@interface WJTapLog : NSObject
+ (void)write:(NSString *)line;
@end

@implementation WJTapLog

+ (NSString *)logPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [[paths firstObject] stringByAppendingPathComponent:@"AutoTapper.log"];
}

+ (void)rotateIfNeeded {
    NSString *p = [self logPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
    unsigned long long sz = [attr[NSFileSize] unsignedLongLongValue];
    if (sz > 256 * 1024) {
        NSString *old = [p stringByAppendingString:@".1"];
        [fm removeItemAtPath:old error:nil];
        [fm moveItemAtPath:p toPath:old error:nil];
    }
}

+ (void)write:(NSString *)line {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *ts = [fmt stringFromDate:[NSDate date]];
    NSString *full = [NSString stringWithFormat:@"%@ %@\n", ts, line];
    @try {
        [self rotateIfNeeded];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:[self logPath]];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:[self logPath] contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:[self logPath]];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
    NSLog(@"[AutoTapper] %@", line);
}

@end

#pragma mark - 控件 tag（设置面板）

typedef NS_ENUM(NSInteger, WJTapControlTag) {
    WJTagIntervalSlider      = 1001,
    WJTagDotCountSlider      = 1002,
    WJTagDotSizeSlider       = 1003,
    WJTagButtonSizeSlider    = 1004,
    WJTagDotAlphaSlider      = 1005,
    WJTagAttackAlphaSlider   = 1006,
    WJTagSettingsAlphaSlider = 1007,
    WJTagAttackModeSeg       = 1008,
    WJTagHideSwitch          = 1009,
    WJTagQuickMountSwitch    = 1010,
    WJTagQuickReviveSwitch   = 1011,
    WJTagQuickReturnSwitch   = 1012,
    WJTagSaveButton          = 1013,
    WJTagCloseButton         = 1014,
    WJTagSteerProtectSwitch  = 1015,
    WJTagSteerXSlider        = 1016,
    WJTagSteerYSlider        = 1017,
    WJTagSteerWSlider        = 1018,
    WJTagSteerHSlider        = 1019,
};

#pragma mark - WJTap

@interface WJTap ()
@property (nonatomic, strong) UIButton *attackButton;
@property (nonatomic, strong) NSMutableArray<UIButton *> *dotButtons;
@property (nonatomic, assign) BOOL isAttacking;
@property (nonatomic, strong) NSTimer *clickTimer;
@property (nonatomic, strong) NSOperationQueue *clickQueue;
@property (nonatomic, strong) UIButton *settingsButton;
@property (nonatomic, strong) UIScrollView *settingsPanel;
@property (nonatomic, strong) UIPanGestureRecognizer *handlePanGesture;
@property (nonatomic, strong) UIPanGestureRecognizer *settingsPanGesture;
@property (nonatomic, assign) BOOL isVerified;

// 设置项
@property (nonatomic, assign) CGFloat clickInterval;       // 默认 0.1s
@property (nonatomic, assign) NSInteger dotCount;          // 默认 6
@property (nonatomic, assign) BOOL shouldHideButtons;      // 默认 NO
@property (nonatomic, assign) CGFloat buttonSize;          // 默认 80
@property (nonatomic, assign) NSInteger attackMode;        // 0=开关 1=滑动 2=隐藏
@property (nonatomic, assign) CGFloat dotAlpha;            // 默认 0.7
@property (nonatomic, assign) CGFloat dotSize;             // 默认 30
@property (nonatomic, assign) CGFloat settingsButtonAlpha; // 默认 1.0
@property (nonatomic, assign) CGFloat attackButtonAlpha;   // 默认 1.0
@property (nonatomic, assign) BOOL enableQuickMount;
@property (nonatomic, assign) BOOL enableQuickReviveMount;
@property (nonatomic, assign) BOOL enableQuickReturnCityMount;

// 方向盘免干扰（游戏优先级）：
//  steerRect = 游戏内虚拟方向盘/摇杆区域（window 坐标，默认左下角）。
//  该区域内：连点器模拟点击一律让位；dot 自动隐藏避免挡手。
@property (nonatomic, assign) BOOL steerProtectEnabled;
@property (nonatomic, assign) CGRect steerRect;
@property (nonatomic, strong) UIView *steerFrameView;
@end

@implementation WJTap {
    BOOL _started;
    BOOL _uiReady;
    BOOL _retryScheduled;
    NSInteger _retryCount;
    UILabel *_intervalValueLabel;
    UILabel *_dotCountValueLabel;
    BOOL _attackDragged;   // 攻钮刚被拖动（短窗口内抑制 toggle 误触发）
}

+ (instancetype)shared {
    static WJTap *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [WJTap new]; });
    return s;
}

#pragma mark - 启动

- (void)startWithReason:(NSString *)reason {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startWithReason:reason];
        });
        return;
    }
    if (_started) return;
    _started = YES;
    _uiReady = NO;

    WJLOG(@"==== AutoTapper bootstrap: app %@ (%@) ====",
          [NSBundle mainBundle].bundleIdentifier ?: @"?", reason);
    WJLOG(@"build: %s %s arch=%s", __DATE__, __TIME__, "arm64");
    WJLOG(@"device=%@ system=%@", [UIDevice currentDevice].model,
          [UIDevice currentDevice].systemVersion);
    WJLOG(@"log file: %@", [WJTapLog logPath]);

    [self loadSettings];
    [self setupUI];
    [self setupThreadPool];
    WJLOG(@"boot: install returned");
}

/// 启动早期 keyWindow 可能尚未就绪：每 0.5s 检查一次，
/// 窗口就绪立即补建 UI（_uiReady 置位后停止）；持续未就绪则降频打日志防刷屏。
- (void)retrySetupIfNeeded {
    if (!_started || _uiReady) return;
    if (_retryScheduled) return;
    _retryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_retryScheduled = NO;
        if (!self->_started || self->_uiReady) return;
        UIWindow *w = [self hostWindow];
        if (w) {
            WJLOG(@"retry: window ready (was nil at boot), setup UI now");
            [self setupUI];
            if (!self->_uiReady) [self retrySetupIfNeeded];
        } else {
            self->_retryCount++;
            if (self->_retryCount % 5 == 1) {
                WJLOG(@"retry: window still nil (%ld)", (long)self->_retryCount);
            }
            [self retrySetupIfNeeded];
        }
    });
}

#pragma mark - 悬浮 UI

- (UIWindow *)hostWindow {
    // 完全不碰 UIScreen（iOS 26 注入场景 +mainScreen 信号级崩溃，实测）。
    // 只用 keyWindow；nil 时退回 windows.firstObject。
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    if (app.keyWindow) return app.keyWindow;
    NSArray<UIWindow *> *wins = app.windows;
    if (wins.count) return wins.firstObject;
    return nil;
}

- (void)setupUI {
    UIWindow *window = [self hostWindow];
    if (!window) {
        WJLOG(@"setupUI: no window yet, will retry");
        [self retrySetupIfNeeded];
        return;
    }
    WJLOG(@"setupUI: window=%@ bounds=%@", window, NSStringFromCGRect(window.bounds));

    self.isVerified = YES;   // 无验证机制：始终视为已验证

    // --- 攻击按钮（红色圆形） ---
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, self.buttonSize, self.buttonSize);
    [btn setBackgroundColor:[UIColor colorWithRed:0.80 green:0.10 blue:0.10 alpha:0.90]];
    btn.layer.cornerRadius = self.buttonSize / 2.0;
    btn.layer.masksToBounds = YES;
    btn.layer.borderWidth = 2.0;
    btn.layer.borderColor = [UIColor whiteColor].CGColor;
    [btn.titleLabel setFont:[UIFont boldSystemFontOfSize:26.0]];
    [btn setTitle:@"攻" forState:UIControlStateNormal];
    btn.alpha = self.attackButtonAlpha;
    btn.center = CGPointMake(window.bounds.size.width / 2.0,
                             window.bounds.size.height / 2.0 + 100);
    self.attackButton = btn;

    [self addDragHandleToAttackButton];
    [self setupAttackButtonEvents];

    [window addSubview:btn];
    [window bringSubviewToFront:btn];

    [self createSettingsButtonInWindow:window];
    [self createDotButtonsWithRadius:100.0 dotSize:self.dotSize inWindow:window dotCount:self.dotCount];

    // 方向盘免干扰：区域未保存过时按常见位置（左下角）补全默认值
    if (![self steerRectWasConfigured]) {
        self.steerRect = CGRectMake(10,
                                    window.bounds.size.height - 190,
                                    160, 160);
        [self saveSettings];
        WJLOG(@"steer: default rect %@", NSStringFromCGRect(self.steerRect));
    }
    [self setupSteerFrameViewInWindow:window];

    [self loadPositionsFromFile];
    [self updateButtonsVisibility];
    _uiReady = YES;
    WJLOG(@"setupUI: done dots=%ld", (long)self.dotButtons.count);
}

- (BOOL)steerRectWasConfigured {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    return ([ud objectForKey:@"WJHookSteerX"] != nil &&
            [ud objectForKey:@"WJHookSteerY"] != nil);
}

/// 方向盘保护区域可视化框：半透明描边，userInteractionEnabled=NO 完全透传触摸
- (void)setupSteerFrameViewInWindow:(UIWindow *)window {
    if (self.steerFrameView) {
        [self.steerFrameView removeFromSuperview];
        self.steerFrameView = nil;
    }
    UIView *v = [[UIView alloc] initWithFrame:self.steerRect];
    v.backgroundColor = [UIColor colorWithWhite:0.95 alpha:0.05];
    v.layer.borderWidth = 2.0;
    v.layer.borderColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:0.55].CGColor;
    v.layer.cornerRadius = 10;
    v.userInteractionEnabled = NO;   // 透传：不挡游戏方向盘的真实触摸
    v.hidden = !self.steerProtectEnabled;
    self.steerFrameView = v;
    [window addSubview:v];
    // 放到悬浮按钮之下，避免视觉遮挡
    [window sendSubviewToBack:v];
    WJLOG(@"steer frame: %@ hidden=%d", NSStringFromCGRect(v.frame), v.hidden);
}

- (void)updateSteerFrame {
    self.steerFrameView.frame = self.steerRect;
    self.steerFrameView.hidden = !self.steerProtectEnabled;
    [self updateButtonsVisibility];
}

- (void)addDragHandleToAttackButton {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleDragHandlePan:)];
    pan.maximumNumberOfTouches = 1;
    // 关键：pan 识别后不吞掉 touches，保证轻点仍触发 TouchUpInside（开关模式不失效）
    pan.cancelsTouchesInView = NO;
    [self.attackButton addGestureRecognizer:pan];
    self.handlePanGesture = pan;
}

- (void)setupAttackButtonEvents {
    [self.attackButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    if (self.attackMode == 2) {
        self.attackButton.hidden = YES;   // 隐藏模式：不显示攻击按钮
    } else if (self.attackMode == 1) {
        // 滑动模式：连点由攻钮拖动驱动（handleDragHandlePan：拖动开始→开始连点，松手→停止）
        [self updateAttackButtonAppearance];
    } else {
        // 开关模式（默认）：点一下开始连点，再点一下停止
        [self.attackButton addTarget:self action:@selector(toggleAttackMode)
                    forControlEvents:UIControlEventTouchUpInside];
        [self updateAttackButtonAppearance];
    }
}

- (void)updateAttackButtonAppearance {
    BOOL attacking = self.isAttacking;
    [self.attackButton setTitle:attacking ? @"停" : @"攻" forState:UIControlStateNormal];
    if (attacking) {
        [self.attackButton setBackgroundColor:[UIColor colorWithRed:0.10 green:0.70 blue:0.20 alpha:0.90]];
    } else {
        [self.attackButton setBackgroundColor:[UIColor colorWithRed:0.80 green:0.10 blue:0.10 alpha:0.90]];
    }
}

- (void)toggleAttackMode {
    // 刚拖动过攻钮（0.4s 内）：这是拖动松手而非点按，不切换
    if (_attackDragged) {
        _attackDragged = NO;
        return;
    }
    WJLOG(@"attack toggle: %@", self.isAttacking ? @"stop" : @"start");
    if (self.isAttacking) {
        [self stopClicking];
    } else {
        [self startClicking];
    }
    [self updateAttackButtonAppearance];
}

- (void)attackButtonTouchDown {
    WJLOG(@"attack down");
    [self startClicking];
    [self startDotAnimation];
}

- (void)attackButtonTouchUp {
    WJLOG(@"attack up");
    [self stopClicking];
    [self stopDotAnimation];
}

#pragma mark - 设置按钮

- (void)createSettingsButtonInWindow:(UIWindow *)window {
    UIButton *sb = [UIButton buttonWithType:UIButtonTypeCustom];
    CGFloat s = 40;
    sb.frame = CGRectMake(0, 0, s, s);
    [sb setBackgroundColor:[UIColor colorWithWhite:0.2 alpha:0.8]];
    sb.layer.cornerRadius = s / 2.0;
    sb.layer.masksToBounds = YES;
    [sb setTitle:@"⚙" forState:UIControlStateNormal];
    [sb.titleLabel setFont:[UIFont boldSystemFontOfSize:18.0]];
    sb.alpha = self.settingsButtonAlpha;
    sb.center = CGPointMake(window.bounds.size.width - 40,
                            window.bounds.size.height / 2.0);
    [sb addTarget:self action:@selector(showSettingsPanel)
                 forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleSettingsDrag:)];
    pan.maximumNumberOfTouches = 1;
    [sb addGestureRecognizer:pan];
    self.settingsPanGesture = pan;
    self.settingsButton = sb;
    [window addSubview:sb];
    [window bringSubviewToFront:sb];
}

- (void)handleSettingsDrag:(UIPanGestureRecognizer *)g {
    UIView *sb = g.view;
    CGPoint t = [g translationInView:sb.superview];
    if (g.state == UIGestureRecognizerStateChanged) {
        sb.center = CGPointMake(sb.center.x + t.x, sb.center.y + t.y);
        [g setTranslation:CGPointZero inView:sb.superview];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        [self savePositionsToFile];
    }
}

#pragma mark - 圆形多点按钮

- (void)createDotButtonsWithRadius:(CGFloat)radius dotSize:(CGFloat)dotSize
                          inWindow:(UIWindow *)window dotCount:(NSInteger)count {
    for (UIButton *old in self.dotButtons) {
        [old removeFromSuperview];
    }
    self.dotButtons = [NSMutableArray array];
    if (count < 1) count = 1;

    CGFloat hueStep = (count > 1) ? (1.0 / count) : 0.0;
    for (NSInteger i = 0; i < count; i++) {
        UIButton *dot = [UIButton buttonWithType:UIButtonTypeCustom];
        dot.frame = CGRectMake(0, 0, dotSize, dotSize);
        CGFloat hue = hueStep * i;
        [dot setBackgroundColor:[UIColor colorWithHue:hue saturation:0.8 brightness:0.9 alpha:1.0]];
        dot.alpha = self.dotAlpha;
        dot.layer.cornerRadius = dotSize / 2.0;
        dot.layer.masksToBounds = YES;
        dot.tag = (NSInteger)(i + 1);          // tag 从 1 起（原版语义：tag==1 为第一点）
        [dot setTitle:[NSString stringWithFormat:@"%ld", (long)(i + 1)]
             forState:UIControlStateNormal];
        [dot.titleLabel setFont:[UIFont boldSystemFontOfSize:dotSize / 2.0]];
        dot.titleLabel.alpha = self.dotAlpha;

        CGFloat ang = (2.0 * M_PI / (CGFloat)count) * (CGFloat)i;
        CGPoint ac = self.attackButton.center;
        dot.center = CGPointMake(ac.x + cos(ang) * radius,
                                 ac.y + sin(ang) * radius);

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(handleDotPan:)];
        pan.maximumNumberOfTouches = 1;
        [dot addGestureRecognizer:pan];
        [dot addTarget:self action:@selector(handleDotTap:)
                     forControlEvents:UIControlEventTouchUpInside];

        [window addSubview:dot];
        [self.dotButtons addObject:dot];
    }
    [window bringSubviewToFront:self.attackButton];
    [window bringSubviewToFront:self.settingsButton];
}

- (void)recreateDotButtons {
    UIWindow *window = [self hostWindow];
    if (window && self.attackButton) {
        [self createDotButtonsWithRadius:100.0 dotSize:self.dotSize
                               inWindow:window dotCount:self.dotCount];
    }
}

- (void)handleDotTap:(UIButton *)dot {
    NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        // 后台线程：随机 0~5ms 微延迟（毫秒级响应，保留一点人手节奏）
        usleep(arc4random_uniform(2) * 5000);
        CGPoint p = [self dotCenterOnMain:dot];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self addScaleAnimationToButton:dot];
            dot.userInteractionEnabled = NO;
            [self simulateTapAtPoint:p];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                dot.userInteractionEnabled = YES;
            });
        });
    }];
    op.qualityOfService = NSQualityOfServiceUserInitiated;
    [self.clickQueue addOperation:op];

    // 隐藏模式（attackMode==2）：点任意非第一点，同时连点第一点
    if (self.attackMode == 2 && dot.tag != 1 && self.dotButtons.count > 0) {
        UIButton *first = self.dotButtons.firstObject;
        NSBlockOperation *op2 = [NSBlockOperation blockOperationWithBlock:^{
            usleep(arc4random_uniform(2) * 5000);
            CGPoint p = [self dotCenterOnMain:first];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self simulateTapAtPoint:p];
            });
        }];
        op2.qualityOfService = NSQualityOfServiceUserInitiated;
        [self.clickQueue addOperation:op2];
    }
}

- (CGPoint)dotCenterOnMain:(UIButton *)dot {
    if ([NSThread isMainThread]) return dot.center;
    __block CGPoint p = CGPointZero;
    dispatch_sync(dispatch_get_main_queue(), ^{ p = dot.center; });
    return p;
}

- (void)handleDotPan:(UIPanGestureRecognizer *)g {
    UIView *dot = g.view;
    CGPoint t = [g translationInView:dot.superview];
    if (g.state == UIGestureRecognizerStateChanged) {
        dot.center = CGPointMake(dot.center.x + t.x, dot.center.y + t.y);
        [g setTranslation:CGPointZero inView:dot.superview];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        [self savePositionsToFile];
        // dot 位置变了，重新评估方向盘区域避让
        [self updateButtonsVisibility];
    }
}

- (void)handleDragHandlePan:(UIPanGestureRecognizer *)g {
    UIView *btn = g.view;
    CGPoint t = [g translationInView:btn.superview];
    if (g.state == UIGestureRecognizerStateBegan) {
        // 滑动模式：开始拖动即开始连点（按住不动不算滑动）
        if (self.attackMode == 1 && !self.isAttacking) {
            [self startClicking];
            [self startDotAnimation];
            [self updateAttackButtonAppearance];
        }
    } else if (g.state == UIGestureRecognizerStateChanged) {
        btn.center = CGPointMake(btn.center.x + t.x, btn.center.y + t.y);
        [g setTranslation:CGPointZero inView:btn.superview];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        if (self.attackMode == 1 && self.isAttacking) {
            [self stopClicking];
            [self stopDotAnimation];
            [self updateAttackButtonAppearance];
        }
        [self savePositionsToFile];
        // 刚拖动过：短窗口内抑制开关模式的 toggle 误触发
        _attackDragged = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self->_attackDragged = NO;
        });
        // 攻击按钮与连点点解耦：拖动只移动按钮本身，点位置保持不动
    }
}

#pragma mark - 动画

- (void)addScaleAnimationToButton:(UIButton *)btn {
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    anim.fromValue = @1.0;
    anim.toValue = @0.6;
    anim.duration = 0.1;
    anim.autoreverses = YES;
    anim.repeatCount = 1;
    [btn.layer addAnimation:anim forKey:@"tapScale"];
}

- (void)startDotAnimation {
    for (UIButton *dot in self.dotButtons) {
        CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        anim.fromValue = @1.0;
        anim.toValue = @1.25;
        anim.duration = 0.35;
        anim.autoreverses = YES;
        anim.repeatCount = HUGE_VALF;
        [dot.layer addAnimation:anim forKey:@"pulse"];
    }
}

- (void)stopDotAnimation {
    for (UIButton *dot in self.dotButtons) {
        [dot.layer removeAnimationForKey:@"pulse"];
    }
}

#pragma mark - 连点引擎

- (void)setupThreadPool {
    NSOperationQueue *q = [NSOperationQueue new];
    q.maxConcurrentOperationCount = (NSInteger)[[NSProcessInfo processInfo] processorCount];
    self.clickQueue = q;
}

- (void)startClicking {
    if (self.clickTimer) {
        [self.clickTimer invalidate];
        self.clickTimer = nil;
    }
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:self.clickInterval
                                                      target:self
                                                    selector:@selector(scheduleClicks)
                                                    userInfo:nil
                                                     repeats:YES];
    self.clickTimer = timer;
    self.isAttacking = YES;
    WJLOG(@"clicking started interval=%.3f dots=%ld", self.clickInterval, (long)self.dotButtons.count);
}

- (void)scheduleClicks {
    // 轮次摘要（限频 1s 一条）：确认每轮实际派发多少个点位
    static NSTimeInterval lastRoundLog = 0;
    NSTimeInterval nowTick = CACurrentMediaTime();
    if (nowTick - lastRoundLog >= 1.0) {
        lastRoundLog = nowTick;
        WJLOG(@"round: %ld dots @ %.0fms", (long)self.dotButtons.count, self.clickInterval * 1000.0);
    }
    for (UIButton *dot in self.dotButtons) {
        NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
            usleep(arc4random_uniform(2) * 5000);   // 毫秒级：0~5ms 随机微延迟
            CGPoint p = [self dotCenterOnMain:dot];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self simulateTapAtPoint:p];
                if (dot.tag == 1) {
                    WJLOG(@"click #1 at %@", NSStringFromCGPoint(p));
                }
            });
        }];
        op.qualityOfService = NSQualityOfServiceUserInitiated;
        [self.clickQueue addOperation:op];
    }
}

- (void)stopClicking {
    if (self.clickTimer) {
        [self.clickTimer invalidate];
        self.clickTimer = nil;
    }
    [self.clickQueue cancelAllOperations];
    self.isAttacking = NO;
    WJLOG(@"clicking stopped");
}

#pragma mark - 触摸模拟（进程内事件派发）

- (UIEvent *)createTouchesEvent {
    @try {
        Class cls = NSClassFromString(@"UITouchesEvent");
        if (!cls) return nil;
        id event = [[cls alloc] init];
        SEL sel = NSSelectorFromString(@"_setTimestamp:");
        if ([event respondsToSelector:sel]) {
            // 注意：_setTimestamp: 参数是 double，必须用 NSInvocation 传值；
            // performSelector:withObject: 传 NSNumber 会被当作指针解包成垃圾值。
            NSMethodSignature *sig = [event methodSignatureForSelector:sel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = event;
                inv.selector = sel;
                double ts = CACurrentMediaTime();
                [inv setArgument:&ts atIndex:2];
                [inv invoke];
            }
        }
        return event;
    } @catch (NSException *e) {
        WJLOG(@"createTouchesEvent ex: %@", e);
        return nil;
    }
}

/// 点击派发诊断日志：限频输出（0.5s 最多一条），避免高频连点刷爆日志
- (void)logTapDiagnostics:(CGPoint)point hit:(UIView *)hit note:(NSString *)note {
    static NSTimeInterval lastTapLog = 0;
    NSTimeInterval now = CACurrentMediaTime();
    if (now - lastTapLog < 0.5) return;
    lastTapLog = now;
    WJLOG(@"tap %@ note=%@ hit=%@ control=%d",
          NSStringFromCGPoint(point), note,
          hit ? NSStringFromClass([hit class]) : @"-",
          hit ? ([hit isKindOfClass:[UIControl class]] ? 1 : 0) : 0);
}

/// 连点引擎是否命中自己悬浮控件（dot/攻击钮/设置钮）——命中则跳过，
/// 避免 hitTest → sendActions → handleDotTap 的自触发循环刷屏/失控。
- (BOOL)isOwnFloatingView:(UIView *)view {
    if (!view) return NO;
    if (view == self.attackButton || view == self.settingsButton) return YES;
    for (UIButton *d in self.dotButtons) {
        if (view == d) return YES;
    }
    return NO;
}

- (void)simulateTapAtPoint:(CGPoint)point {
    if (!self.isVerified) return;
    UIWindow *window = [self hostWindow];
    if (!window) {
        [self logTapDiagnostics:point hit:nil note:@"no-window"];
        return;
    }
    // 游戏优先级：方向盘区域内的模拟点击一律让位（真实手控移动优先）
    if (self.steerProtectEnabled && CGRectContainsPoint(self.steerRect, point)) {
        [self logTapDiagnostics:point hit:nil note:@"steer-blocked"];
        return;
    }
    UIView *hit = [window hitTest:point withEvent:nil];
    if (!hit) {
        [self logTapDiagnostics:point hit:nil note:@"no-hit"];
        return;
    }
    if ([self isOwnFloatingView:hit]) {
        [self logTapDiagnostics:point hit:hit note:@"own-view"];
        return;
    }
    [self logTapDiagnostics:point hit:hit note:@"ok"];

    if (![hit isKindOfClass:[UIControl class]]) {
        @try {
            UITouch *touch = [[UITouch alloc] init];
            [touch setValue:@0 forKey:@"_phase"];                          // UITouchPhaseBegan
            [touch setValue:hit forKey:@"_view"];
            [touch setValue:@1 forKey:@"_tapCount"];
            [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"_locationInWindow"];
            UIEvent *event = [self createTouchesEvent];
            NSSet *touches = [NSSet setWithObject:touch];
            [hit touchesBegan:touches withEvent:event];
            [touch setValue:@3 forKey:@"_phase"];                          // UITouchPhaseEnded
            [hit touchesEnded:touches withEvent:event];
        } @catch (NSException *e) {
            WJLOG(@"simulateTap ex: %@", e);
        }
    } else {
        // 命中 UIControl：直接触发 TouchUpInside（如游戏内按钮）
        @try {
            [(UIControl *)hit sendActionsForControlEvents:UIControlEventTouchUpInside];
        } @catch (NSException *e) {
            WJLOG(@"simulateTap control ex: %@", e);
        }
    }
}

#pragma mark - 可见性

- (void)updateButtonsVisibility {
    if (self.shouldHideButtons) {
        self.attackButton.hidden = YES;
        for (UIButton *d in self.dotButtons) d.hidden = YES;
    } else {
        // dot 落在方向盘保护区域内时自动隐藏，避免挡住真实触摸移动
        for (UIButton *d in self.dotButtons) {
            BOOL inSteer = self.steerProtectEnabled &&
                           CGRectContainsPoint(self.steerRect, d.center);
            d.hidden = inSteer;
        }
        if (self.attackMode == 2) {
            self.attackButton.hidden = YES;
        } else {
            self.attackButton.hidden = NO;
        }
    }
    self.settingsButton.hidden = NO;
}

#pragma mark - 设置面板

- (void)showSettingsPanel {
    UIWindow *window = [self hostWindow];
    if (!window) return;
    if (self.settingsPanel && self.settingsPanel.superview) {
        [self.settingsPanel removeFromSuperview];
        return;
    }

    CGFloat w = 280;
    CGFloat rowH = 44;
    CGFloat pad = 12;
    CGFloat top = 14;
    CGFloat h = top + 36 + 17 * rowH + 70;   // 36 = 顶部标题区高度
    // 面板过高时压缩可视高度，内容仍完整可滚动（UIScrollView）
    CGFloat maxH = window.bounds.size.height * 0.62;
    if (h > maxH) h = maxH;

    UIScrollView *panel = [[UIScrollView alloc] initWithFrame:
        CGRectMake(window.bounds.size.width - w - 12, 60, w, h)];
    panel.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
    panel.layer.cornerRadius = 14;
    panel.layer.masksToBounds = YES;
    panel.alwaysBounceVertical = YES;
    panel.showsVerticalScrollIndicator = YES;
    self.settingsPanel = panel;
    [window addSubview:panel];
    [window bringSubviewToFront:panel];

    // 面板顶部标题
    UILabel *panelTitle = [[UILabel alloc] initWithFrame:CGRectMake(0, top, w, 34)];
    panelTitle.text = @"老玩家连点";
    panelTitle.textColor = [UIColor whiteColor];
    panelTitle.font = [UIFont boldSystemFontOfSize:18];
    panelTitle.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:panelTitle];

    __block CGFloat y = top + 36;

    void (^addRow)(NSString *, UIView *) = ^(NSString *title, UIView *ctrl) {
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, 96, rowH)];
        lab.text = title;
        lab.textColor = [UIColor whiteColor];
        lab.font = [UIFont systemFontOfSize:13];
        lab.textAlignment = NSTextAlignmentLeft;
        [panel addSubview:lab];
        ctrl.frame = CGRectMake(pad + 100, y + 6, w - pad * 2 - 100, 30);
        [panel addSubview:ctrl];
        y += rowH;
    };

    // 点击间隔（毫秒级：5ms~2000ms，右侧实时显示数值）
    UILabel *intervalLab = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, 96, rowH)];
    intervalLab.text = @"点击间隔";
    intervalLab.textColor = [UIColor whiteColor];
    intervalLab.font = [UIFont systemFontOfSize:13];
    intervalLab.textAlignment = NSTextAlignmentLeft;
    [panel addSubview:intervalLab];
    UISlider *interval = [UISlider new];
    interval.minimumValue = 0.01; interval.maximumValue = 0.5;   // 10~500ms（对齐反编译原版）
    interval.value = self.clickInterval; interval.tag = WJTagIntervalSlider;
    [interval addTarget:self action:@selector(intervalSliderChanged:) forControlEvents:UIControlEventValueChanged];
    interval.frame = CGRectMake(pad + 100, y + 6, w - pad * 2 - 100 - 64, 30);
    [panel addSubview:interval];
    UILabel *intervalVal = [[UILabel alloc] initWithFrame:CGRectMake(w - pad - 60, y + 6, 60, 30)];
    intervalVal.text = [NSString stringWithFormat:@"%.0f ms", self.clickInterval * 1000.0];
    intervalVal.textColor = [UIColor colorWithRed:0.45 green:0.85 blue:1.0 alpha:1.0];
    intervalVal.font = [UIFont boldSystemFontOfSize:13];
    intervalVal.textAlignment = NSTextAlignmentRight;
    [panel addSubview:intervalVal];
    _intervalValueLabel = intervalVal;
    y += rowH;

    // 点数量（右侧实时标注当前连点位个数）
    UILabel *dotCountLab = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, 96, rowH)];
    dotCountLab.text = @"点数量";
    dotCountLab.textColor = [UIColor whiteColor];
    dotCountLab.font = [UIFont systemFontOfSize:13];
    dotCountLab.textAlignment = NSTextAlignmentLeft;
    [panel addSubview:dotCountLab];
    UISlider *dotCountS = [UISlider new];
    dotCountS.minimumValue = 1; dotCountS.maximumValue = 10;
    dotCountS.value = self.dotCount; dotCountS.tag = WJTagDotCountSlider;
    [dotCountS addTarget:self action:@selector(dotCountSliderChanged:) forControlEvents:UIControlEventValueChanged];
    dotCountS.frame = CGRectMake(pad + 100, y + 6, w - pad * 2 - 100 - 64, 30);
    [panel addSubview:dotCountS];
    UILabel *dotCountVal = [[UILabel alloc] initWithFrame:CGRectMake(w - pad - 60, y + 6, 60, 30)];
    dotCountVal.text = [NSString stringWithFormat:@"%ld 个", (long)self.dotCount];
    dotCountVal.textColor = [UIColor colorWithRed:0.45 green:0.85 blue:1.0 alpha:1.0];
    dotCountVal.font = [UIFont boldSystemFontOfSize:13];
    dotCountVal.textAlignment = NSTextAlignmentRight;
    [panel addSubview:dotCountVal];
    _dotCountValueLabel = dotCountVal;
    y += rowH;

    // 点大小
    UISlider *dotSizeS = [UISlider new];
    dotSizeS.minimumValue = 12; dotSizeS.maximumValue = 60;
    dotSizeS.value = self.dotSize; dotSizeS.tag = WJTagDotSizeSlider;
    [dotSizeS addTarget:self action:@selector(dotSizeSliderChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"点大小", dotSizeS);

    // 按钮大小
    UISlider *btnSizeS = [UISlider new];
    btnSizeS.minimumValue = 40; btnSizeS.maximumValue = 120;
    btnSizeS.value = self.buttonSize; btnSizeS.tag = WJTagButtonSizeSlider;
    [btnSizeS addTarget:self action:@selector(buttonSizeSliderChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"攻击按钮", btnSizeS);

    // 点透明度
    UISlider *alphaS = [UISlider new];
    alphaS.minimumValue = 0.2; alphaS.maximumValue = 1.0;
    alphaS.value = self.dotAlpha; alphaS.tag = WJTagDotAlphaSlider;
    [alphaS addTarget:self action:@selector(alphaSliderChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"点透明度", alphaS);

    // 攻击按钮透明度
    UISlider *attackAlphaS = [UISlider new];
    attackAlphaS.minimumValue = 0.2; attackAlphaS.maximumValue = 1.0;
    attackAlphaS.value = self.attackButtonAlpha; attackAlphaS.tag = WJTagAttackAlphaSlider;
    [attackAlphaS addTarget:self action:@selector(attackButtonAlphaSliderChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"攻击钮透明度", attackAlphaS);

    // 设置按钮透明度
    UISlider *settingsAlphaS = [UISlider new];
    settingsAlphaS.minimumValue = 0.2; settingsAlphaS.maximumValue = 1.0;
    settingsAlphaS.value = self.settingsButtonAlpha; settingsAlphaS.tag = WJTagSettingsAlphaSlider;
    [settingsAlphaS addTarget:self action:@selector(settingsButtonAlphaSliderChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"设置钮透明度", settingsAlphaS);

    // 攻击模式
    UISegmentedControl *mode = [[UISegmentedControl alloc] initWithItems:@[@"开关", @"滑动", @"隐藏"]];
    mode.selectedSegmentIndex = self.attackMode; mode.tag = WJTagAttackModeSeg;
    [mode addTarget:self action:@selector(attackModeChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"攻击模式", mode);

    // 隐藏按钮
    UISwitch *hide = [UISwitch new];
    hide.on = self.shouldHideButtons; hide.tag = WJTagHideSwitch;
    [hide addTarget:self action:@selector(hideSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"隐藏按钮", hide);

    // 快捷复活 / 快捷回城（原版附带，仅持久化）
    UISwitch *qr = [UISwitch new];
    qr.on = self.enableQuickReviveMount; qr.tag = WJTagQuickReviveSwitch;
    [qr addTarget:self action:@selector(quickReviveMountSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"快捷复活", qr);

    UISwitch *qc = [UISwitch new];
    qc.on = self.enableQuickReturnCityMount; qc.tag = WJTagQuickReturnSwitch;
    [qc addTarget:self action:@selector(quickReturnCityMountSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"快捷回城", qc);

    // ---- 方向盘免干扰（游戏优先级） ----
    UISwitch *steerSw = [UISwitch new];
    steerSw.on = self.steerProtectEnabled; steerSw.tag = WJTagSteerProtectSwitch;
    [steerSw addTarget:self action:@selector(steerProtectSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"方向盘免干扰", steerSw);

    CGFloat bw = window.bounds.size.width;
    CGFloat bh = window.bounds.size.height;

    UISlider *sx = [UISlider new];
    sx.minimumValue = 0; sx.maximumValue = bw;
    sx.value = self.steerRect.origin.x; sx.tag = WJTagSteerXSlider;
    [sx addTarget:self action:@selector(steerXSliderChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"方向盘X", sx);

    UISlider *sy = [UISlider new];
    sy.minimumValue = 0; sy.maximumValue = bh;
    sy.value = self.steerRect.origin.y; sy.tag = WJTagSteerYSlider;
    [sy addTarget:self action:@selector(steerYSliderChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"方向盘Y", sy);

    UISlider *sw2 = [UISlider new];
    sw2.minimumValue = 80; sw2.maximumValue = 240;
    sw2.value = self.steerRect.size.width; sw2.tag = WJTagSteerWSlider;
    [sw2 addTarget:self action:@selector(steerWSliderChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"方向盘宽", sw2);

    UISlider *sh2 = [UISlider new];
    sh2.minimumValue = 80; sh2.maximumValue = 240;
    sh2.value = self.steerRect.size.height; sh2.tag = WJTagSteerHSlider;
    [sh2 addTarget:self action:@selector(steerHSliderChanged:) forControlEvents:UIControlEventValueChanged];
    addRow(@"方向盘高", sh2);

    // 保存 + 关闭
    UIButton *save = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    [save setTitle:@"保存" forState:UIControlStateNormal];
    [save setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    save.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:0.9 alpha:1.0];
    save.layer.cornerRadius = 6;
    save.tag = WJTagSaveButton;
    [save addTarget:self action:@selector(saveButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    save.frame = CGRectMake(pad, y + 4, w / 2 - pad - 4, 36);

    UIButton *close = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.backgroundColor = [UIColor colorWithWhite:0.35 alpha:1.0];
    close.layer.cornerRadius = 6;
    close.tag = WJTagCloseButton;
    [close addTarget:self action:@selector(closeSettingsPanel) forControlEvents:UIControlEventTouchUpInside];
    close.frame = CGRectMake(w / 2 + 4, y + 4, w / 2 - pad - 4, 36);

    [panel addSubview:save];
    [panel addSubview:close];
    y += 48;

    panel.contentSize = CGSizeMake(w, y + 8);
}

- (void)closeSettingsPanel {
    [self.settingsPanel removeFromSuperview];
    self.settingsPanel = nil;
}

#pragma mark - 设置面板控件回调

- (void)intervalSliderChanged:(UISlider *)s {
    self.clickInterval = s.value;
    _intervalValueLabel.text = [NSString stringWithFormat:@"%.0f ms", s.value * 1000.0];
    if (self.isAttacking) [self startClicking];   // 连点中：重启 timer，新间隔立即生效
}
- (void)dotCountSliderChanged:(UISlider *)s {
    NSInteger v = (NSInteger)lround(s.value);
    if (v < 1) v = 1;
    _dotCountValueLabel.text = [NSString stringWithFormat:@"%ld 个", (long)v];
    if (v != self.dotCount) {
        self.dotCount = v;
        [self recreateDotButtons];
        [self updateButtonsVisibility];
    }
}
- (void)dotSizeSliderChanged:(UISlider *)s {
    self.dotSize = s.value;
    [self recreateDotButtons];
    [self updateButtonsVisibility];
}
- (void)buttonSizeSliderChanged:(UISlider *)s {
    self.buttonSize = s.value;
    [self updateAttackButtonSize];
}
- (void)alphaSliderChanged:(UISlider *)s {
    self.dotAlpha = s.value;
    for (UIButton *d in self.dotButtons) {
        d.alpha = s.value;
        d.titleLabel.alpha = s.value;
    }
}
- (void)attackButtonAlphaSliderChanged:(UISlider *)s {
    self.attackButtonAlpha = s.value;
    self.attackButton.alpha = s.value;
}
- (void)settingsButtonAlphaSliderChanged:(UISlider *)s {
    self.settingsButtonAlpha = s.value;
    self.settingsButton.alpha = s.value;
}
- (void)attackModeChanged:(UISegmentedControl *)c {
    self.attackMode = c.selectedSegmentIndex;
    [self setupAttackButtonEvents];
    [self updateButtonsVisibility];
    if (self.isAttacking) [self stopClicking];
}
- (void)hideSwitchChanged:(UISwitch *)sw {
    self.shouldHideButtons = sw.on;
    [self updateButtonsVisibility];
}
- (void)quickMountSwitchChanged:(UISwitch *)sw { self.enableQuickMount = sw.on; }
- (void)quickReviveMountSwitchChanged:(UISwitch *)sw { self.enableQuickReviveMount = sw.on; }
- (void)quickReturnCityMountSwitchChanged:(UISwitch *)sw { self.enableQuickReturnCityMount = sw.on; }

// ---- 方向盘免干扰回调 ----
- (void)steerProtectSwitchChanged:(UISwitch *)sw {
    self.steerProtectEnabled = sw.on;
    WJLOG(@"steer protect %@ rect=%@", sw.on ? @"ON" : @"OFF",
          NSStringFromCGRect(self.steerRect));
    [self updateSteerFrame];
}
- (void)steerXSliderChanged:(UISlider *)s {
    self.steerRect = CGRectMake(s.value, self.steerRect.origin.y,
                                self.steerRect.size.width, self.steerRect.size.height);
    [self updateSteerFrame];
}
- (void)steerYSliderChanged:(UISlider *)s {
    self.steerRect = CGRectMake(self.steerRect.origin.x, s.value,
                                self.steerRect.size.width, self.steerRect.size.height);
    [self updateSteerFrame];
}
- (void)steerWSliderChanged:(UISlider *)s {
    self.steerRect = CGRectMake(self.steerRect.origin.x, self.steerRect.origin.y,
                                s.value, self.steerRect.size.height);
    [self updateSteerFrame];
}
- (void)steerHSliderChanged:(UISlider *)s {
    self.steerRect = CGRectMake(self.steerRect.origin.x, self.steerRect.origin.y,
                                self.steerRect.size.width, s.value);
    [self updateSteerFrame];
}

- (void)updateAttackButtonSize {
    self.attackButton.frame = CGRectMake(0, 0, self.buttonSize, self.buttonSize);
    self.attackButton.layer.cornerRadius = self.buttonSize / 2.0;
}

- (void)saveButtonTapped {
    [self saveSettings];
    [self savePositionsToFile];
    WJLOG(@"settings saved");
    [self closeSettingsPanel];
}

#pragma mark - 持久化

- (void)loadSettings {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    self.clickInterval = [ud floatForKey:@"WJHookClickInterval"];
    if (self.clickInterval == 0) self.clickInterval = 0.05;   // 默认 50ms（毫秒级连点）
    self.dotCount = [ud integerForKey:@"WJHookDotCount"];
    if (self.dotCount == 0) self.dotCount = 6;
    self.shouldHideButtons = [ud boolForKey:@"WJHookShouldHideButtons"];
    self.buttonSize = [ud floatForKey:@"WJHookButtonSize"];
    if (self.buttonSize == 0) self.buttonSize = 80;
    // 攻击模式：v12 起语义 0=开关 1=滑动 2=隐藏；v11 及以前 0=按住 1=切换 2=隐藏
    // 首次运行 v12 时做一次性迁移，保证旧设置行为不变、新装默认开关模式
    if (![ud boolForKey:@"WJHookAttackModeMigratedV12"]) {
        if ([ud objectForKey:@"WJHookAttackMode"]) {
            NSInteger legacy = [ud integerForKey:@"WJHookAttackMode"];
            if (legacy == 0) self.attackMode = 1;        // 旧"按住" → 新"滑动"（行为一致）
            else if (legacy == 1) self.attackMode = 0;   // 旧"切换" → 新"开关"（行为一致）
            else self.attackMode = 2;                    // 隐藏不变
        } else {
            self.attackMode = 0;                          // 新装：默认开关
        }
        [ud setBool:YES forKey:@"WJHookAttackModeMigratedV12"];
        [ud synchronize];
    } else {
        self.attackMode = [ud integerForKey:@"WJHookAttackMode"];
    }
    self.dotAlpha = [ud floatForKey:@"WJHookDotAlpha"];
    if (self.dotAlpha == 0) self.dotAlpha = 0.7;
    self.dotSize = [ud floatForKey:@"WJHookDotSize"];
    if (self.dotSize == 0) self.dotSize = 30;
    self.settingsButtonAlpha = [ud floatForKey:@"WJHookSettingsButtonAlpha"];
    if (self.settingsButtonAlpha == 0) self.settingsButtonAlpha = 1.0;
    self.attackButtonAlpha = [ud floatForKey:@"WJHookAttackButtonAlpha"];
    if (self.attackButtonAlpha == 0) self.attackButtonAlpha = 1.0;
    self.enableQuickReviveMount = [ud boolForKey:@"WJHookEnableQuickReviveMount"];
    self.enableQuickReturnCityMount = [ud boolForKey:@"WJHookEnableQuickReturnCityMount"];
    self.enableQuickMount = [ud boolForKey:@"WJHookEnableQuickMount"];

    // 方向盘免干扰：默认开启，区域默认左下角（setupUI 里按窗口尺寸补全）
    if ([ud objectForKey:@"WJHookSteerProtectEnabled"]) {
        self.steerProtectEnabled = [ud boolForKey:@"WJHookSteerProtectEnabled"];
    } else {
        self.steerProtectEnabled = YES;
    }
    CGFloat sx = [ud floatForKey:@"WJHookSteerX"];
    CGFloat sy = [ud floatForKey:@"WJHookSteerY"];
    CGFloat sw = [ud floatForKey:@"WJHookSteerW"];
    CGFloat sh = [ud floatForKey:@"WJHookSteerH"];
    self.steerRect = CGRectMake(sx, sy, sw > 0 ? sw : 160, sh > 0 ? sh : 160);

    WJLOG(@"settings loaded: interval=%.2f dots=%ld mode=%ld steer=%@ rect=%@",
          self.clickInterval, (long)self.dotCount, (long)self.attackMode,
          self.steerProtectEnabled ? @"ON" : @"OFF",
          NSStringFromCGRect(self.steerRect));
}

- (void)saveSettings {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setFloat:(float)self.clickInterval forKey:@"WJHookClickInterval"];
    [ud setInteger:self.dotCount forKey:@"WJHookDotCount"];
    [ud setBool:self.shouldHideButtons forKey:@"WJHookShouldHideButtons"];
    [ud setFloat:(float)self.buttonSize forKey:@"WJHookButtonSize"];
    [ud setInteger:self.attackMode forKey:@"WJHookAttackMode"];
    [ud setBool:YES forKey:@"WJHookAttackModeMigratedV12"];   // 已进入 v12 新语义，停止迁移
    [ud setFloat:(float)self.dotAlpha forKey:@"WJHookDotAlpha"];
    [ud setFloat:(float)self.dotSize forKey:@"WJHookDotSize"];
    [ud setFloat:(float)self.settingsButtonAlpha forKey:@"WJHookSettingsButtonAlpha"];
    [ud setFloat:(float)self.attackButtonAlpha forKey:@"WJHookAttackButtonAlpha"];
    [ud setBool:self.enableQuickReviveMount forKey:@"WJHookEnableQuickReviveMount"];
    [ud setBool:self.enableQuickReturnCityMount forKey:@"WJHookEnableQuickReturnCityMount"];
    [ud setBool:self.enableQuickMount forKey:@"WJHookEnableQuickMount"];
    [ud setBool:self.steerProtectEnabled forKey:@"WJHookSteerProtectEnabled"];
    [ud setFloat:(float)self.steerRect.origin.x forKey:@"WJHookSteerX"];
    [ud setFloat:(float)self.steerRect.origin.y forKey:@"WJHookSteerY"];
    [ud setFloat:(float)self.steerRect.size.width forKey:@"WJHookSteerW"];
    [ud setFloat:(float)self.steerRect.size.height forKey:@"WJHookSteerH"];
    [ud synchronize];
}

- (NSString *)positionsPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [[paths firstObject] stringByAppendingPathComponent:@"WJTapPositions.plist"];
}

- (void)savePositionsToFile {
    @try {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        dict[@"attack"] = NSStringFromCGPoint(self.attackButton.center);
        dict[@"settings"] = NSStringFromCGPoint(self.settingsButton.center);
        NSMutableArray *dots = [NSMutableArray array];
        for (UIButton *d in self.dotButtons) {
            [dots addObject:NSStringFromCGPoint(d.center)];
        }
        dict[@"dots"] = dots;
        BOOL ok = [dict writeToFile:[self positionsPath] atomically:YES];
        WJLOG(@"positions saved: %d (%ld dots)", ok, (long)dots.count);
    } @catch (NSException *e) {
        WJLOG(@"savePositions ex: %@", e);
    }
}

- (void)loadPositionsFromFile {
    @try {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[self positionsPath]];
        if (!dict) return;
        NSString *attack = dict[@"attack"];
        NSString *settings = dict[@"settings"];
        NSArray *dots = dict[@"dots"];
        if (attack) self.attackButton.center = CGPointFromString(attack);
        if (settings) self.settingsButton.center = CGPointFromString(settings);
        if (dots.count && dots.count == self.dotButtons.count) {
            for (NSInteger i = 0; i < self.dotButtons.count; i++) {
                self.dotButtons[i].center = CGPointFromString(dots[i]);
            }
        }
        WJLOG(@"positions loaded: dots=%ld", (long)dots.count);
    } @catch (NSException *e) {
        WJLOG(@"loadPositions ex: %@", e);
    }
}

@end
