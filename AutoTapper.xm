//
//  AutoTapper.xm — 注入入口（无钩子，纯 +load / %ctor 驱动）
//
//  机制：%config(generator=internal) 产物为纯 ObjC 注入库，不依赖
//  CydiaSubstrate/越狱框架，证书签名侧载可用。
//
//  启动链（iOS 26 实测结论）：
//   * UIApplicationDidFinishLaunchingNotification 在 iOS 26 注入进程里不派发
//   * UIApplicationDidBecomeActiveNotification 可靠派发
//   * 3 秒兜底定时器
//  全部触发来源写入日志，便于定位"哪条链路启动了"。
//

#import <UIKit/UIKit.h>
#import "WJTapCore.h"

%config(generator=internal)

static BOOL gStarted = NO;

static void startTap(NSString *reason) {
    if (gStarted) return;
    gStarted = YES;
    [[WJTap shared] startWithReason:reason];
}

%ctor {
    @autoreleasepool {
        // 观察者：didFinishLaunching（部分 iOS 版本派发）
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
                                                          startTap(@"didFinishLaunching");
                                                      }];
        // 观察者：didBecomeActive（iOS 26 注入进程实测可靠）
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
                                                          startTap(@"didBecomeActive");
                                                      }];
        // 兜底：3 秒后仍未启动则强行启动
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (!gStarted) {
                               startTap(@"3s-fallback");
                           }
                       });
    }
}
