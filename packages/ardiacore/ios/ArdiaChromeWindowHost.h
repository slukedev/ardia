#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ArdiaChromeWindowHost : NSObject

@property(class, nonatomic, readonly) CGFloat windowCornerRadius;
@property(class, nonatomic, readonly) CGFloat drawnWindowCornerRadius;

+ (CGFloat)frameCornerRadiusOfWindow:(NSWindow *)window;

+ (nullable NSWindow *)makeWindowForProfile:(NSString *)profile;
+ (nullable NSWindow *)makeWindowForProfile:(NSString *)profile chromeWindow:(nullable NSString *)chromeWindow;
+ (nullable NSWindow *)makeWindowForProfile:(NSString *)profile
                               chromeWindow:(nullable NSString *)chromeWindow
                                  appWindow:(nullable NSString *)appWindow;

+ (void)floatForWindowManagers:(NSWindow *)window;
+ (void)floatOverActiveSpace:(NSWindow *)window;

+ (void)recordLaunchLayout;
+ (void)forgetLaunchPictures;
+ (BOOL)takeDismissedAppWindow:(NSString *)appWindow;

+ (void)embedRootView:(NSView *)root inWindow:(NSWindow *)window;

+ (nullable NSView *)rootViewOfWindow:(NSWindow *)window;
+ (nullable NSView *)embeddedRootOfWindow:(NSWindow *)window;
@property(class, nonatomic, readonly) Class contentViewClass;

+ (void)removeRootViewOfWindow:(NSWindow *)window;

+ (void)setTrafficLightsCenter:(nullable NSValue *)center trailing:(BOOL)trailing inWindow:(NSWindow *)window;
+ (void)moveTrafficLightsCenter:(nullable NSValue *)center trailing:(BOOL)trailing inWindow:(NSWindow *)window;
+ (void)insetTrafficLightsOfWindow:(NSWindow *)window NS_SWIFT_NAME(insetTrafficLights(of:));

+ (void)closeWindow:(NSWindow *)window;

+ (NSSize)windowSizeFromInterfaceSize:(NSSize)size forWindow:(nullable NSWindow *)window NS_SWIFT_NAME(windowSize(fromInterface:for:));
+ (void)setInterfaceMinSize:(NSSize)size ofWindow:(NSWindow *)window NS_SWIFT_NAME(setInterfaceMinSize(_:of:));
+ (void)keepInterfaceContentSizeOfWindow:(NSWindow *)window NS_SWIFT_NAME(keepInterfaceContentSize(of:));

+ (void)showProfile:(NSString *)profile inWindow:(NSWindow *)window;
+ (void)showProfile:(NSString *)profile
           inWindow:(NSWindow *)window
             report:(nullable void (^)(BOOL profileLoaded, double activeMs, double swapMs, BOOL heldTimedOut))report;
+ (void)prepareProfiles:(NSArray<NSString *> *)profiles forWindow:(NSWindow *)window;
@property(class, nonatomic, copy, nullable) void (^swappedHandler)(NSWindow *from, NSWindow *to);

@property(class, nonatomic, copy, nullable) BOOL (^shouldCloseHandler)(NSWindow *window);
@property(class, nonatomic, copy, nullable) BOOL (^refusesUnhandledKeyHandler)(NSWindow *window, NSEvent *event);
@property(class, nonatomic, copy, nullable) NSString *(^focusHandoffSummaryHandler)(NSWindow *window);
+ (BOOL)windowShouldClose:(NSWindow *)window;
+ (BOOL)windowFullScreenIsForPage:(NSWindow *)window;
+ (BOOL)windowIsFullScreen:(NSWindow *)window NS_SWIFT_NAME(windowIsFullScreen(_:));
+ (BOOL)userSeesWindow:(nullable NSWindow *)window NS_SWIFT_NAME(userSees(_:));
+ (BOOL)userSeesOnlyThroughWindowServer:(nullable NSWindow *)window NS_SWIFT_NAME(userSeesOnlyThroughWindowServer(_:));
+ (void)reconsiderSightOfWindow:(nullable NSWindow *)window NS_SWIFT_NAME(reconsiderSight(of:));
@property(class, nonatomic, copy, nullable) BOOL (^playsForAutoPictureInPictureHandler)(NSWindow *window);

@end

@interface ArdiaChromeWindowHost (PictureInPicture)

+ (BOOL)isVideoPictureInPictureWindow:(NSWindow *)window;
+ (BOOL)consumePictureInPictureActivation;
+ (BOOL)activateForPictureInPictureReturn;

@end

extern NSNotificationName const ArdiaWindowSeenDidChange;

NSView *_Nullable ArdiaWindowRootView(NSWindow *_Nullable window);
NSValue *_Nullable ArdiaTrafficLightsCenter(NSWindow *_Nullable window);
BOOL ArdiaTrafficLightsTrailing(NSWindow *_Nullable window);
FOUNDATION_EXPORT BOOL ArdiaPerformReservedKey(NSEvent *event);

@interface ArdiaChromeWindowHost (AccessibilityTitle)

@property(class, nonatomic, copy, nullable) void (^accessibilityTitleReadHandler)(NSWindow *window);

@end

@interface ArdiaChromeWindowHost (LittleFit)

+ (nullable NSValue *)littleFrameFittingLandingOf:(NSWindow *)window
                                      minimumSize:(NSSize)minimum
                                       wantedSize:(nullable NSValue *)wanted
                                      placedFrame:(nullable NSValue *)placed
    NS_SWIFT_NAME(littleFrameFittingLanding(of:minimumSize:wantedSize:placedFrame:));
+ (NSRect)littleFrameForSize:(NSSize)size
                  minimumSize:(NSSize)minimum
                 visibleFrame:(NSRect)visible NS_SWIFT_NAME(littleFrame(for:minimumSize:visibleFrame:));

@end

@interface ArdiaChromeWindowHost (Dev)

+ (nullable NSString *)devAction:(NSString *)action window:(NSWindow *)window;

@end

@interface ArdiaChromeWindowHost (DevFullScreenProbe)

+ (NSString *)devFullScreenProbe:(nullable NSString *)argument window:(NSWindow *)window;

@end

NS_ASSUME_NONNULL_END
