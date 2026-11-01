//
//  YGOverlayController.m — 悬浮球 + 准星 + 控制面板
//
//  UI 结构（全部手动布局，不依赖 nib / storyboard，避免 rootless 下资源路径问题）：
//
//    YGOverlayWindow (level = Alert + 2000)
//      └─ YGOverlayRootView (hitTest 只放行 tag==kYGTouchableTag 的子视图)
//           ├─ YGCrosshairView    标记点（可拖 / 可微调）
//           ├─ YGBallView         悬浮球（拖动 / 单击开面板 / 双击启停）
//           └─ YGPanelView        控制面板（点悬浮球弹出）
//
//  交互：
//    * 拖动悬浮球 → 移动球（吸附边缘）
//    * 单击悬浮球 → 开/关面板
//    * 双击悬浮球 → 开始/停止
//    * 拖动准星   → 标记/移动目标点
//    * 音量减键   → 停止（由 YGVolumeButton 提供）
//

#import "YGCore.h"
#import "YGPrivateAPI.h"

#pragma mark - 常量

static const CGFloat kYGBallSize       = 56.0;
static const CGFloat kYGPanelWidth     = 268.0;
static const CGFloat kYGPanelPadding   = 12.0;

#pragma mark - 小工具：按钮

static UIButton *YGMakeButton(NSString *title, UIColor *bg, id target, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 8.0;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static UILabel *YGMakeLabel(NSString *text, CGFloat size, UIColor *color) {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont monospacedDigitSystemFontOfSize:size weight:UIFontWeightRegular];
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

#pragma mark - 面板

@interface YGPanelView : UIView
@property (nonatomic, weak) YGOverlayController *controller;
@property (nonatomic, strong) UIButton *startStopBtn;
@property (nonatomic, strong) UILabel  *statusLabel;
@property (nonatomic, strong) UILabel  *hintLabel;
@property (nonatomic, strong) UISlider *intervalSlider;
@property (nonatomic, strong) UILabel  *intervalLabel;
@property (nonatomic, strong) UISlider *holdSlider;
@property (nonatomic, strong) UILabel  *holdLabel;
@property (nonatomic, strong) UISegmentedControl *backendSeg;
@property (nonatomic, strong) UISwitch *volSwitch;
@property (nonatomic, strong) UISwitch *crossSwitch;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, assign) CGFloat  fineStep;
- (void)buildUI;
- (void)refresh;
- (void)appendLogLine:(NSString *)line;
@end

@interface YGOverlayController () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) YGOverlayWindow  *window;
@property (nonatomic, strong) YGBallView       *ball;
@property (nonatomic, strong) YGCrosshairView  *crosshair;
@property (nonatomic, strong) YGPanelView      *panel;
@property (nonatomic, strong) UIPanGestureRecognizer *panelPan;
@property (nonatomic, assign) BOOL              panelVisible;
@property (nonatomic, assign) BOOL              installed;
@property (nonatomic, assign) CGPoint           ballStartCenter;
@property (nonatomic, assign) CGPoint           crossStartCenter;
@end

#pragma mark - YGPanelView 实现

@implementation YGPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.94];
        self.layer.cornerRadius = 16.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.6;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 12;
        self.layer.shadowOffset = CGSizeMake(0, 6);
        self.tag = [YGOverlayWindow touchableTag];   // 让 root view 放行触摸
        _fineStep = 1.0;
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    YGConfig *cfg = YGConfig.shared;
    CGFloat W = kYGPanelWidth - kYGPanelPadding * 2;
    CGFloat y = kYGPanelPadding;

    // 标题
    UILabel *title = YGMakeLabel(@"AutoTapper", 15, [UIColor whiteColor]);
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    title.frame = CGRectMake(kYGPanelPadding, y, W - 30, 20);
    [self addSubview:title];

    UIButton *closeBtn = YGMakeButton(@"✕", [UIColor colorWithWhite:1 alpha:0.12],
                                      self, @selector(onClose));
    closeBtn.frame = CGRectMake(kYGPanelWidth - kYGPanelPadding - 26, y - 2, 26, 24);
    [self addSubview:closeBtn];
    y += 26;

    // 状态
    _statusLabel = YGMakeLabel(@"", 10, [UIColor colorWithWhite:0.7 alpha:1]);
    _statusLabel.frame = CGRectMake(kYGPanelPadding, y, W, 14);
    [self addSubview:_statusLabel];
    y += 18;

    // 开始/停止
    _startStopBtn = YGMakeButton(@"开始循环点击", [UIColor colorWithRed:0.12 green:0.62 blue:0.40 alpha:1],
                                 self, @selector(onStartStop));
    _startStopBtn.frame = CGRectMake(kYGPanelPadding, y, W, 42);
    _startStopBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [self addSubview:_startStopBtn];
    y += 50;

    // 提示
    _hintLabel = YGMakeLabel(@"音量减键 = 停止   双击悬浮球 = 启停", 9.5,
                             [UIColor colorWithWhite:0.55 alpha:1]);
    _hintLabel.frame = CGRectMake(kYGPanelPadding, y, W, 13);
    [self addSubview:_hintLabel];
    y += 20;

    // ---- 间隔 ----
    _intervalLabel = YGMakeLabel(@"", 11, [UIColor colorWithWhite:0.88 alpha:1]);
    _intervalLabel.frame = CGRectMake(kYGPanelPadding, y, W, 14);
    [self addSubview:_intervalLabel];
    y += 16;

    _intervalSlider = [UISlider new];
    _intervalSlider.minimumValue = 0.02f;
    _intervalSlider.maximumValue = 5.0f;
    _intervalSlider.value = (float)MIN(MAX(cfg.interval, 0.02), 5.0);
    _intervalSlider.frame = CGRectMake(kYGPanelPadding, y, W, 28);
    _intervalSlider.continuous = YES;
    [_intervalSlider addTarget:self action:@selector(onIntervalChange:)
              forControlEvents:UIControlEventValueChanged];
    [self addSubview:_intervalSlider];
    y += 34;

    // ---- 按压时长 ----
    _holdLabel = YGMakeLabel(@"", 11, [UIColor colorWithWhite:0.88 alpha:1]);
    _holdLabel.frame = CGRectMake(kYGPanelPadding, y, W, 14);
    [self addSubview:_holdLabel];
    y += 16;

    _holdSlider = [UISlider new];
    _holdSlider.minimumValue = 0.02f;
    _holdSlider.maximumValue = 0.30f;
    _holdSlider.value = (float)MIN(MAX(cfg.holdDuration, 0.02), 0.30);
    _holdSlider.frame = CGRectMake(kYGPanelPadding, y, W, 28);
    _holdSlider.continuous = YES;
    [_holdSlider addTarget:self action:@selector(onHoldChange:)
          forControlEvents:UIControlEventValueChanged];
    [self addSubview:_holdSlider];
    y += 34;

    // ---- 微调 ----
    UILabel *fineTitle = YGMakeLabel(@"微调目标点", 11, [UIColor colorWithWhite:0.88 alpha:1]);
    fineTitle.frame = CGRectMake(kYGPanelPadding, y, W, 14);
    [self addSubview:fineTitle];
    y += 18;

    UISegmentedControl *stepSeg = [[UISegmentedControl alloc] initWithItems:@[@"1pt", @"5pt", @"10pt"]];
    stepSeg.selectedSegmentIndex = 0;
    stepSeg.frame = CGRectMake(kYGPanelPadding, y, W, 28);
    if (@available(iOS 13.0, *)) {
        stepSeg.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.20];
    }
    [stepSeg addTarget:self action:@selector(onStepChange:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:stepSeg];
    y += 34;

    // 方向键 3x3（中间是「设为屏幕中心」）
    CGFloat bw = (W - 8) / 3.0;
    CGFloat bh = 30.0;
    NSArray *titles = @[@"↑", @"●", @"↓", @"←", @"⊙", @"→"];
    NSArray *sels = @[@"onNudgeUp:", @"onNudgeUp:", @"onNudgeDown:",
                      @"onNudgeLeft:", @"onCenter:", @"onNudgeRight:"];
    // 布局：第一行 ↑ ● ；第二行 ← ⊙ → ；第三行 ↓
    // 简化成两行三列：↑ ● ↓ / ← ⊙ →
    for (int i = 0; i < 6; i++) {
        int row = i / 3, col = i % 3;
        UIButton *b = YGMakeButton(titles[i], [UIColor colorWithWhite:1 alpha:0.13],
                                   self, NSSelectorFromString(sels[i]));
        b.frame = CGRectMake(kYGPanelPadding + col * (bw + 4),
                             y + row * (bh + 4), bw, bh);
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        [self addSubview:b];
    }
    y += 2 * (bh + 4) + 6;

    // ---- 后端选择 ----
    UILabel *bkTitle = YGMakeLabel(@"注入后端", 11, [UIColor colorWithWhite:0.88 alpha:1]);
    bkTitle.frame = CGRectMake(kYGPanelPadding, y, W, 14);
    [self addSubview:bkTitle];
    y += 16;

    _backendSeg = [[UISegmentedControl alloc] initWithItems:@[@"自动", @"HID", @"SB-HID", @"UITouch"]];
    _backendSeg.frame = CGRectMake(kYGPanelPadding, y, W, 28);
    _backendSeg.selectedSegmentIndex = cfg.backend <= 3 ? cfg.backend : 0;
    if (@available(iOS 13.0, *)) {
        _backendSeg.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.20];
    }
    [_backendSeg addTarget:self action:@selector(onBackendChange:)
          forControlEvents:UIControlEventValueChanged];
    [self addSubview:_backendSeg];
    y += 34;

    // ---- 开关 ----
    UILabel *volLbl = YGMakeLabel(@"音量减键停止", 11.5, [UIColor colorWithWhite:0.88 alpha:1]);
    volLbl.frame = CGRectMake(kYGPanelPadding, y, W - 56, 28);
    [self addSubview:volLbl];

    _volSwitch = [UISwitch new];
    _volSwitch.on = cfg.volumeDownStops;
    _volSwitch.transform = CGAffineTransformMakeScale(0.8, 0.8);
    _volSwitch.frame = CGRectMake(kYGPanelWidth - kYGPanelPadding - 48, y, 48, 28);
    [_volSwitch addTarget:self action:@selector(onVolSwitch:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_volSwitch];
    y += 32;

    UILabel *crLbl = YGMakeLabel(@"显示准星", 11.5, [UIColor colorWithWhite:0.88 alpha:1]);
    crLbl.frame = CGRectMake(kYGPanelPadding, y, W - 56, 28);
    [self addSubview:crLbl];

    _crossSwitch = [UISwitch new];
    _crossSwitch.on = cfg.showCrosshair;
    _crossSwitch.transform = CGAffineTransformMakeScale(0.8, 0.8);
    _crossSwitch.frame = CGRectMake(kYGPanelWidth - kYGPanelPadding - 48, y, 48, 28);
    [_crossSwitch addTarget:self action:@selector(onCrossSwitch:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_crossSwitch];
    y += 34;

    // ---- 日志 ----
    _logView = [[UITextView alloc] initWithFrame:CGRectMake(kYGPanelPadding, y, W, 76)];
    _logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    _logView.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    _logView.font = [UIFont monospacedSystemFontOfSize:8.5 weight:UIFontWeightRegular];
    _logView.editable = NO;
    _logView.scrollEnabled = YES;
    _logView.layer.cornerRadius = 6;
    _logView.textContainerInset = UIEdgeInsetsMake(4, 4, 4, 4);
    [self addSubview:_logView];
    y += 82;

    self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y,
                            kYGPanelWidth, y + kYGPanelPadding - 6);

    [self refresh];
}

#pragma mark 面板动作

- (void)onClose {
    [self.controller togglePanel];
}

- (void)onStartStop {
    if ([YGTapEngine shared].isRunning) [[YGTapEngine shared] stop];
    else [[YGTapEngine shared] start];
    [self refresh];
    [self.controller refreshCrosshair];
}

- (void)onIntervalChange:(UISlider *)s {
    YGConfig *cfg = YGConfig.shared;
    cfg.interval = s.value;
    [cfg save];
    [self refresh];

    /*
     * 运行中改间隔必须重建 timer —— dispatch_source 的 interval 是创建时定死的，
     * 改 cfg 不会影响已经 resume 的 source。旧实现里拖完滑块「看起来生效了」
     * 其实还在按老间隔点，直到手动停一次再开。
     * 用 250ms 去抖：continuous 滑块拖动时会连发几十次 valueChanged，
     * 每次都 restart 会把引擎卡在「刚停就起」的抖动里。
     */
    if ([YGTapEngine shared].isRunning) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                 selector:@selector(applyIntervalRestart)
                                                   object:nil];
        [self performSelector:@selector(applyIntervalRestart)
                   withObject:nil
                   afterDelay:0.25];
    }
}

- (void)applyIntervalRestart {
    [[YGTapEngine shared] restartIfRunning];
}

- (void)onHoldChange:(UISlider *)s {
    YGConfig *cfg = YGConfig.shared;
    cfg.holdDuration = s.value;
    [cfg save];
    [self refresh];
}

- (void)onStepChange:(UISegmentedControl *)seg {
    NSArray *steps = @[@1.0, @5.0, @10.0];
    self.fineStep = [steps[seg.selectedSegmentIndex] doubleValue];
}

- (void)nudge:(CGPoint)d {
    YGConfig *cfg = YGConfig.shared;
    CGSize size = YGScreenSize();
    CGPoint p = cfg.hasTarget ? cfg.targetPoint
                              : CGPointMake(size.width / 2, size.height / 2);
    p.x = MIN(MAX(p.x + d.x, 1), size.width  - 1);
    p.y = MIN(MAX(p.y + d.y, 1), size.height - 1);
    cfg.targetPoint = p;
    cfg.hasTarget = YES;
    [cfg save];
    [self.controller refreshCrosshair];
    [self refresh];
}

- (void)onNudgeUp    { [self nudge:CGPointMake(0, -self.fineStep)]; }
- (void)onNudgeDown  { [self nudge:CGPointMake(0,  self.fineStep)]; }
- (void)onNudgeLeft  { [self nudge:CGPointMake(-self.fineStep, 0)]; }
- (void)onNudgeRight { [self nudge:CGPointMake( self.fineStep, 0)]; }

- (void)onCenter {
    YGConfig *cfg = YGConfig.shared;
    CGSize size = YGScreenSize();
    cfg.targetPoint = CGPointMake(size.width / 2, size.height / 2);
    cfg.hasTarget = YES;
    [cfg save];
    [self.controller refreshCrosshair];
    [self refresh];
}

- (void)onBackendChange:(UISegmentedControl *)seg {
    YGInjectBackend map[] = { YGInjectBackendAuto, YGInjectBackendHID,
                              YGInjectBackendSpringHID, YGInjectBackendUITouch };
    [[YGInjector shared] setBackend:map[seg.selectedSegmentIndex]];
    [self refresh];
}

- (void)onVolSwitch:(UISwitch *)s {
    YGConfig.shared.volumeDownStops = s.on;
    [YGConfig.shared save];
}

- (void)onCrossSwitch:(UISwitch *)s {
    YGConfig.shared.showCrosshair = s.on;
    [YGConfig.shared save];
    [self.controller refreshCrosshair];
}

#pragma mark 刷新

- (void)refresh {
    YGConfig *cfg = YGConfig.shared;
    YGTapEngine *eng = [YGTapEngine shared];
    BOOL running = eng.isRunning;

    [_startStopBtn setTitle:(running ? @"停止" : @"开始循环点击") forState:UIControlStateNormal];
    _startStopBtn.backgroundColor = running
        ? [UIColor colorWithRed:0.82 green:0.22 blue:0.22 alpha:1]
        : [UIColor colorWithRed:0.12 green:0.62 blue:0.40 alpha:1];

    _intervalLabel.text = [NSString stringWithFormat:@"循环间隔  %.2f s", cfg.interval];
    _holdLabel.text     = [NSString stringWithFormat:@"按压时长  %.2f s", cfg.holdDuration];

    _intervalSlider.value = (float)MIN(MAX(cfg.interval, 0.02), 5.0);
    _holdSlider.value     = (float)MIN(MAX(cfg.holdDuration, 0.02), 0.30);

    _volSwitch.on   = cfg.volumeDownStops;
    _crossSwitch.on = cfg.showCrosshair;

    NSString *pointStr = cfg.hasTarget
        ? [NSString stringWithFormat:@"(%.1f, %.1f)", cfg.targetPoint.x, cfg.targetPoint.y]
        : @"未标记（拖准星或点 ⊙）";

    _hintLabel.text = [NSString stringWithFormat:@"目标 %@", pointStr];

    _statusLabel.text = [NSString stringWithFormat:@"%@  %@  点击 %lu  失败 %lu",
                         running ? @"● 运行中" : @"○ 已停止",
                         [[YGInjector shared] activeBackendName],
                         (unsigned long)eng.ticks,
                         (unsigned long)eng.fails];
    _statusLabel.textColor = running
        ? [UIColor colorWithRed:0.55 green:0.95 blue:0.72 alpha:1]
        : [UIColor colorWithWhite:0.68 alpha:1];
}

- (void)appendLogLine:(NSString *)line {
    if (!line.length) return;
    NSString *cur = _logView.text ?: @"";
    // 只保留最后 40 行，避免 UITextView 越来越慢
    NSArray<NSString *> *lines = [cur componentsSeparatedByString:@"\n"];
    if (lines.count > 40) {
        cur = [[lines subarrayWithRange:NSMakeRange(lines.count - 40, 40)]
               componentsJoinedByString:@"\n"];
    }
    _logView.text = cur.length ? [cur stringByAppendingFormat:@"\n%@", line] : line;
    if (_logView.text.length) {
        NSRange r = NSMakeRange(_logView.text.length - 1, 1);
        [_logView scrollRangeToVisible:r];
    }
}

@end

#pragma mark - YGOverlayController 实现

@implementation YGOverlayController

// 显式绑定 ivar：类扩展把 installed 改成了 readwrite，但头文件是 readonly，
// 手写 getter 之外必须让编译器生成 _installed（否则 _installed 未声明）。
@synthesize installed = _installed;

+ (instancetype)shared {
    static YGOverlayController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [YGOverlayController new]; });
    return s;
}

#pragma mark 安装

- (void)install {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self install]; });
        return;
    }
    if (_installed) return;

    YGConfig *cfg = YGConfig.shared;
    CGSize size = YGScreenSize();
    YGLOG(@"overlay install: size=%@", NSStringFromCGSize(size));

    // ---- 窗口（场景查询防御化：iOS 26 上启动早期枚举场景可能崩）----
    UIWindowScene *scene = nil;
    @try {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)s;
                if (ws.activationState == UISceneActivationStateForegroundActive) { scene = ws; break; }
            }
        }
        if (!scene) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
            }
        }
    } @catch (NSException *e) {
        YGLOG(@"overlay install: scene lookup exception: %@", e);
        scene = nil;
    }
    YGLOG(@"overlay install: scene=%@", scene);

    _window = [[YGOverlayWindow alloc] initWithWindowScene:scene];
    YGLOG(@"overlay install: window=%@", _window);
    _window.frame = CGRectMake(0, 0, size.width, size.height);
    [_window yg_present];
    YGLOG(@"overlay install: presented");

    UIView *root = [_window ygContentRoot];

    // ---- 准星 ----
    _crosshair = [[YGCrosshairView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    _crosshair.tag = [YGOverlayWindow touchableTag];
    _crosshair.hidden = !cfg.showCrosshair;
    CGPoint tp = cfg.hasTarget ? cfg.targetPoint
                               : CGPointMake(size.width / 2, size.height / 2);
    _crosshair.targetPoint = tp;
    _crosshair.running = NO;
    [root addSubview:_crosshair];

    UIPanGestureRecognizer *crossPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onCrosshairPan:)];
    crossPan.minimumNumberOfTouches = 1;
    crossPan.maximumNumberOfTouches = 1;
    crossPan.delegate = self;
    [_crosshair addGestureRecognizer:crossPan];

    UITapGestureRecognizer *crossTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onCrosshairTap:)];
    [_crosshair addGestureRecognizer:crossTap];

    // ---- 悬浮球 ----
    _ball = [[YGBallView alloc] initWithFrame:CGRectMake(0, 0, kYGBallSize, kYGBallSize)];
    _ball.tag = [YGOverlayWindow touchableTag];
    CGPoint bc = cfg.ballCenter;
    if (bc.x <= 0 && bc.y <= 0) {
        bc = CGPointMake(size.width - kYGBallSize / 2 - 10,
                         size.height * 0.62);
    }
    bc.x = MIN(MAX(bc.x, kYGBallSize / 2 + 2), size.width  - kYGBallSize / 2 - 2);
    bc.y = MIN(MAX(bc.y, kYGBallSize / 2 + 2), size.height - kYGBallSize / 2 - 2);
    _ball.center = bc;
    _ball.alpha = cfg.ballAlpha > 0 ? cfg.ballAlpha : 0.85;
    _ball.hidden = cfg.ballHidden;
    _ball.badge = @"";
    [root addSubview:_ball];

    UIPanGestureRecognizer *ballPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onBallPan:)];
    ballPan.delegate = self;
    [_ball addGestureRecognizer:ballPan];

    UITapGestureRecognizer *ballTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBallTap:)];
    ballTap.numberOfTapsRequired = 1;
    [_ball addGestureRecognizer:ballTap];

    UITapGestureRecognizer *ballDouble =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBallDoubleTap:)];
    ballDouble.numberOfTapsRequired = 2;
    [_ball addGestureRecognizer:ballDouble];
    [ballTap requireGestureRecognizerToFail:ballDouble];

    _installed = YES;
    YGLOG(@"overlay installed, window=%@ level=%.0f", _window, _window.windowLevel);

    // ---- 通知 ----
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(onEngineStateChanged:)
               name:YGTapEngineDidStopNotification object:nil];
    [nc addObserver:self selector:@selector(onEngineStateChanged:)
               name:YGTapEngineDidFailStartNotification object:nil];
    [nc addObserver:self selector:@selector(onLogAppended:)
               name:YGLogDidAppendNotification object:nil];

    if (@available(iOS 13.0, *)) {
        [nc addObserver:self selector:@selector(onSceneChanged:)
                   name:UISceneDidActivateNotification object:nil];
        [nc addObserver:self selector:@selector(onSceneChanged:)
                   name:UISceneWillConnectNotification object:nil];
        [nc addObserver:self selector:@selector(onSceneChanged:)
                   name:UISceneDidDisconnectNotification object:nil];
    }

    [self refreshCrosshair];
}

- (void)uninstall {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self uninstall]; });
        return;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _window.ygPanelView = nil;      // 弱引用，防止 uninstall 后仍指向已释放的面板
    [_panel removeFromSuperview];
    _panel = nil;
    [_crosshair removeFromSuperview];
    _crosshair = nil;
    [_ball removeFromSuperview];
    _ball = nil;
    _window.hidden = YES;
    _window = nil;
    _installed = NO;
    YGLOG(@"overlay uninstalled");
}

#pragma mark 场景

- (void)rebindScene {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self rebindScene]; });
        return;
    }
    if (!_installed) return;

    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) { scene = ws; break; }
    }
    if (!scene) return;

    // 已经绑在同一个 scene 上 → 只更新 frame
    if (@available(iOS 13.0, *)) {
        if (_window.windowScene == scene) {
            _window.frame = scene.coordinateSpace.bounds;
            return;
        }
    }

    YGLOG(@"rebindScene → %@", scene);
    // 换 scene 必须重建窗口：UIWindow 的 windowScene 是只读的，无法改绑
    YGOverlayController *keep = self;
    BOOL wasPanelVisible = keep->_panelVisible;
    CGPoint ballCenter = _ball.center;
    [self uninstall];
    [self install];
    _ball.center = ballCenter;
    if (wasPanelVisible) [self togglePanel];
}

- (void)onSceneChanged:(NSNotification *)note {
    // 场景切换后下一 runloop 再绑，此时 scene 状态已经稳定
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self rebindScene];
    });
}

#pragma mark 手势

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

/// 面板上的 pan 只在「非交互控件」上生效。
/// 不做这个判断的话，UISlider / UISwitch / 分段控件的手势会被 panel pan 抢走。
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == _panelPan) {
        CGPoint p = [g locationInView:_panel];
        UIView *hit = [_panel hitTest:p withEvent:nil];
        UIView *v = hit;
        while (v && v != _panel) {
            if ([v isKindOfClass:[UIControl class]] ||
                [v isKindOfClass:[UITextView class]] ||
                [v isKindOfClass:[UIScrollView class]]) {
                return NO;      // 交给控件自己处理
            }
            v = v.superview;
        }
    }
    return YES;
}

- (void)onBallPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    CGSize size = YGScreenSize();

    if (g.state == UIGestureRecognizerStateBegan) {
        _ballStartCenter = v.center;
    }

    CGFloat half = kYGBallSize / 2;
    CGPoint c = CGPointMake(_ballStartCenter.x + t.x, _ballStartCenter.y + t.y);
    c.x = MIN(MAX(c.x, half + 2), size.width  - half - 2);
    c.y = MIN(MAX(c.y, half + 2), size.height - half - 2);
    v.center = c;

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        // 吸附到最近的左右边缘，避免挡住内容
        CGFloat snapX = (c.x < size.width / 2) ? half + 6 : size.width - half - 6;
        [UIView animateWithDuration:0.22
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            v.center = CGPointMake(snapX, c.y);
        } completion:^(BOOL finished) {
            YGConfig *cfg = YGConfig.shared;
            cfg.ballCenter = v.center;
            [cfg save];
            if (self->_panelVisible) [self positionPanelNearBall];
        }];
    }
}

- (void)onBallTap:(UITapGestureRecognizer *)g {
    [self togglePanel];
}

- (void)onBallDoubleTap:(UITapGestureRecognizer *)g {
    if ([YGTapEngine shared].isRunning) [[YGTapEngine shared] stop];
    else [[YGTapEngine shared] start];
    [self refreshCrosshair];
    [_panel refresh];
}

- (void)onCrosshairPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    CGSize size = YGScreenSize();

    if (g.state == UIGestureRecognizerStateBegan) {
        _crossStartCenter = v.center;
    }

    CGPoint c = CGPointMake(_crossStartCenter.x + t.x, _crossStartCenter.y + t.y);
    c.x = MIN(MAX(c.x, 1), size.width  - 1);
    c.y = MIN(MAX(c.y, 1), size.height - 1);
    v.center = c;

    if (g.state == UIGestureRecognizerStateChanged) {
        // 拖动过程中实时更新，松手才落盘（写文件别在拖动里做）
        _crosshair.targetPoint = c;
        [_panel refresh];
    }

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        YGConfig *cfg = YGConfig.shared;
        cfg.targetPoint = c;
        cfg.hasTarget = YES;
        [cfg save];
        _crosshair.targetPoint = c;
        [_panel refresh];
        YGLOG(@"目标点标记为 (%.1f, %.1f)", c.x, c.y);
    }
}

- (void)onCrosshairTap:(UITapGestureRecognizer *)g {
    // 单击准星 = 直接把当前准星位置设为标记点（拖动后已设，这里给个确认反馈）
    YGConfig *cfg = YGConfig.shared;
    cfg.targetPoint = _crosshair.center;
    cfg.hasTarget = YES;
    [cfg save];
    [_panel refresh];
    [self refreshCrosshair];
}

#pragma mark 面板

- (void)togglePanel {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self togglePanel]; });
        return;
    }
    if (!_installed) return;

    if (_panelVisible) {
        _panelVisible = NO;
        [UIView animateWithDuration:0.16 animations:^{
            self->_panel.alpha = 0;
            self->_panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
        } completion:^(BOOL f) {
            self->_panel.hidden = YES;
        }];
        return;
    }

    _panelVisible = YES;
    if (!_panel) {
        _panel = [[YGPanelView alloc] initWithFrame:CGRectMake(0, 0, kYGPanelWidth, 400)];
        _panel.controller = self;
        [[_window ygContentRoot] addSubview:_panel];
        // 面板永远可交互：落点让行规则在 window 的 hitTest 里会让整窗穿透，
        // 只有登记了 ygPanelView 才能把它排除在外（否则运行时按不到「停止」）
        _window.ygPanelView = _panel;
        // 面板可整体拖动（方便让开被点的区域）。
        // ★ 关键：手势必须放行 UIControl（UISlider/UISwitch/UISegmentedControl）
        //   和 UITextView，否则 pan 会先截获触摸，滑块完全拖不动。
        _panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                            action:@selector(onPanelPan:)];
        _panelPan.delegate = self;
        [_panel addGestureRecognizer:_panelPan];
    }
    _panel.hidden = NO;
    _panel.alpha = 0;
    _panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [self positionPanelNearBall];
    [_panel refresh];

    [UIView animateWithDuration:0.2
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_panel.alpha = 1;
        self->_panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)onPanelPan:(UIPanGestureRecognizer *)g {
    // 只允许拖到「标题区」——这里用位移阈值近似：任何拖动都移动面板，
    // 但滑块/按钮的交互优先（UISlider 会自己吞掉触摸）
    UIView *p = g.view;
    CGPoint t = [g translationInView:p.superview];
    if (g.state == UIGestureRecognizerStateBegan) {
        _ballStartCenter = p.center;
    }
    CGSize size = YGScreenSize();
    CGPoint c = CGPointMake(_ballStartCenter.x + t.x, _ballStartCenter.y + t.y);
    c.x = MIN(MAX(c.x, p.bounds.size.width / 2), size.width  - p.bounds.size.width / 2);
    c.y = MIN(MAX(c.y, p.bounds.size.height / 2), size.height - p.bounds.size.height / 2);
    p.center = c;
}

- (void)positionPanelNearBall {
    if (!_panel || !_ball) return;
    CGSize size = YGScreenSize();
    CGFloat pw = kYGPanelWidth;
    CGFloat ph = _panel.bounds.size.height;

    BOOL ballOnLeft = _ball.center.x < size.width / 2;
    CGFloat x = ballOnLeft ? (_ball.center.x + kYGBallSize / 2 + 8)
                           : (_ball.center.x - kYGBallSize / 2 - 8 - pw);
    x = MIN(MAX(x, 6), size.width - pw - 6);

    CGFloat y = _ball.center.y - ph / 2;
    y = MIN(MAX(y, 40), size.height - ph - 20);

    _panel.frame = CGRectMake(x, y, pw, ph);
}

- (void)refreshPanel {
    [_panel refresh];
}

#pragma mark 层级自愈

- (void)ensureTopmostLevel:(CGFloat)otherLevel {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self ensureTopmostLevel:otherLevel]; });
        return;
    }
    if (!_installed || !_window) return;

    // 只往上抬，绝不往下压：否则别的窗口一出现就会把悬浮球顶下去，看着像消失了。
    CGFloat need = otherLevel + 100.0;
    if (_window.windowLevel < need) {
        CGFloat old = _window.windowLevel;
        _window.windowLevel = need;
        YGLOG(@"overlay level %.0f → %.0f (对方 %.0f)", old, need, otherLevel);
    }
}

- (void)reviveIfNeeded {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self reviveIfNeeded]; });
        return;
    }
    // 窗口被系统回收（内存警告 / scene 重建）后，_installed 还是 YES 但 _window 已无效
    if (_installed && _window && _window.hidden == NO && _ball.superview) return;

    if (_installed) {
        YGLOG(@"overlay 掉线，重建");
        [self uninstall];
    }
    [self install];
}

#pragma mark 准星

- (void)refreshCrosshair {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshCrosshair]; });
        return;
    }
    if (!_crosshair) return;
    YGConfig *cfg = YGConfig.shared;

    _crosshair.hidden = !cfg.showCrosshair;
    if (cfg.hasTarget) {
        _crosshair.targetPoint = cfg.targetPoint;
    }
    _crosshair.running = [YGTapEngine shared].isRunning;
    [_crosshair setNeedsDisplay];

    BOOL running = [YGTapEngine shared].isRunning;
    _ball.running = running;
    _ball.badge = running ? [NSString stringWithFormat:@"%lu", (unsigned long)[YGTapEngine shared].ticks] : @"";
}

#pragma mark 通知

- (void)onEngineStateChanged:(NSNotification *)n {
    [self refreshCrosshair];
    [_panel refresh];
}

- (void)onLogAppended:(NSNotification *)n {
    NSString *line = n.object;
    if (![line isKindOfClass:[NSString class]]) return;
    // 面板日志只放关键行，避免刷屏
    if ([line containsString:@"tap("] || [line containsString:@"probe:"]) {
        // 高频行丢弃（每 tick 都有）
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_panel appendLogLine:line];
    });
}

@end
