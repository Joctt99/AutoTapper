//
//  WJTapCore.h — 连点器核心（WJHook 机制重写版，无验证/支付/远程机制）
//
//  来源：libWJHook 反编译还原（Ghidra），按可编译 ObjC 重写。
//  去掉：performVerification / verifyAuthCode / initiatePayment / expiry /
//        screenshot 上报 / loadRemoteLibraryFromURL / socket / rebind_symbols。
//  保留：悬浮攻击按钮 + 圆形多点 + 设置面板 + 连点引擎 + 持久化。
//
//  关键设计（规避 iOS 26 注入崩溃）：
//   * 完全不碰 UIScreen（屏幕几何一律取自 keyWindow）
//   * 触摸模拟为进程内事件派发（UITouch KVC + 直接 touchesBegan/Ended），
//     不依赖越狱/HID/IOHIDEvent
//

#import <UIKit/UIKit.h>

@interface WJTap : NSObject

+ (instancetype)shared;

/// 启动连点器 UI（多级触发入口，来源写入日志便于定位）
- (void)startWithReason:(NSString *)reason;

@property (nonatomic, assign, readonly) BOOL started;

@end
