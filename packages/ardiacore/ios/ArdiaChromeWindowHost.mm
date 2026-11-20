#import "ArdiaChromeWindowInternal.h"
#import "ArdiaEarlyWindow.h"
#import "ArdiaInterfaceScale.h"
#import "ArdiaPictureInPictureInternal.h"
#import "ArdiaRuntime.h"
#import "ArdiaWebViewInternal.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <cmath>

using namespace ardia_window;

namespace {

BOOL (^gShouldClose)(NSWindow *);
BOOL (^gPlaysForAutoPictureInPicture)(NSWindow *);

void (^gSwapped)(NSWindow *, NSWindow *);

NSString *(^gFocusHandoffSummary)(NSWindow *);

const void *const kFloatsForWindowManagersKey = &kFloatsForWindowManagersKey;

void AnswerFloatingSubrole(Class windowClass) {
  static NSMutableSet<Class> *answered = [NSMutableSet set];
  if (!windowClass || [answered containsObject:windowClass]) return;
  [answered addObject:windowClass];
  ardia_runtime::ReplaceMethod(windowClass, @selector(accessibilitySubrole), ^id(IMP original) {
    return ^NSAccessibilitySubrole(NSWindow *window) {
      if (objc_getAssociatedObject(window, kFloatsForWindowManagersKey)) return NSAccessibilitySystemFloatingWindowSubrole;
      return ((NSAccessibilitySubrole (*)(id, SEL))original)(window, @selector(accessibilitySubrole));
    };
  });
}

const void *const kInterfaceMinSizeKey = &kInterfaceMinSizeKey;

const void *const kInterfaceContentScaleKey = &kInterfaceContentScaleKey;

NSRect VisibleFrameOf(NSWindow *window) {
  NSScreen *screen = window.screen ?: NSScreen.mainScreen;
  return screen ? screen.visibleFrame : NSMakeRect(0, 0, CGFLOAT_MAX, CGFLOAT_MAX);
}

NSSize WithinVisibleFrame(NSSize size, NSWindow *window) {
  const NSRect visible = VisibleFrameOf(window);
  return NSMakeSize(MIN(size.width, floor(NSWidth(visible))), MIN(size.height, floor(NSHeight(visible))));
}

NSRect OnScreen(NSRect frame, NSWindow *window) {
  const NSRect visible = VisibleFrameOf(window);
  if (NSMaxX(frame) > NSMaxX(visible)) frame.origin.x = NSMaxX(visible) - NSWidth(frame);
  if (NSMinX(frame) < NSMinX(visible)) frame.origin.x = NSMinX(visible);
  if (NSMinY(frame) < NSMinY(visible)) frame.origin.y = NSMinY(visible);
  if (NSMaxY(frame) > NSMaxY(visible)) frame.origin.y = NSMaxY(visible) - NSHeight(frame);
  return frame;
}

NSSize InterfaceSize(NSSize size, NSWindow *window) {
  const NSSize scaled = [ArdiaInterfaceScale windowSizeFromRoot:size];
  return WithinVisibleFrame(NSMakeSize(round(scaled.width), round(scaled.height)), window);
}

void SetFrameKeepingTop(NSWindow *window, NSSize size) {
  const NSRect was = window.frame;
  const NSRect frame = OnScreen(NSMakeRect(NSMinX(was), NSMaxY(was) - size.height, size.width, size.height), window);
  if (!NSEqualRects(frame, was)) [window setFrame:frame display:window.visible];
}

void ApplyInterfaceMinSize(NSWindow *window, BOOL grow) {
  NSValue *design = objc_getAssociatedObject(window, kInterfaceMinSizeKey);
  if (!design) return;
  const NSSize minimum = InterfaceSize(design.sizeValue, window);
  window.minSize = minimum;
  if (!grow || (window.styleMask & NSWindowStyleMaskFullScreen)) return;
  const NSSize size = window.frame.size;
  if (size.width >= minimum.width && size.height >= minimum.height) return;
  SetFrameKeepingTop(window, NSMakeSize(MAX(size.width, minimum.width), MAX(size.height, minimum.height)));
}

void RescaleInterfaceContent(NSWindow *window) {
  NSNumber *was = objc_getAssociatedObject(window, kInterfaceContentScaleKey);
  if (!was) return;
  const CGFloat scale = ArdiaInterfaceScale.scale;
  objc_setAssociatedObject(window, kInterfaceContentScaleKey, @(scale), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (was.doubleValue == scale || !(was.doubleValue > 0) || (window.styleMask & NSWindowStyleMaskFullScreen)) return;
  const NSSize content = [window contentRectForFrameRect:window.frame].size;
  const CGFloat ratio = scale / was.doubleValue;
  const NSSize scaled = NSMakeSize(round(content.width * ratio), round(content.height * ratio));
  const NSSize frame = [window frameRectForContentRect:NSMakeRect(0, 0, scaled.width, scaled.height)].size;
  SetFrameKeepingTop(window, WithinVisibleFrame(frame, window));
}

void FollowInterfaceScale() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [NSNotificationCenter.defaultCenter addObserverForName:ArdiaInterfaceScaleDidChange
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification *) {
                                                  for (NSWindow *window in NSApp.windows) {
                                                    ApplyInterfaceMinSize(window, NO);
                                                    RescaleInterfaceContent(window);
                                                    ApplyInterfaceMinSize(window, YES);
                                                  }
                                                }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidChangeScreenNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification *note) {
                                                  if (NSWindow *window = note.object; [window isKindOfClass:NSWindow.class])
                                                    ApplyInterfaceMinSize(window, NO);
                                                }];
  });
}

}

NSView *ArdiaWindowRootView(NSWindow *window) {
  return [ArdiaChromeWindowHost rootViewOfWindow:window] ?: window.contentView;
}

@implementation ArdiaChromeWindowHost

+ (CGFloat)windowCornerRadius {
  return WindowCornerRadius(nil);
}

+ (CGFloat)drawnWindowCornerRadius {
  return DrawnWindowCornerRadius(nil);
}

+ (CGFloat)frameCornerRadiusOfWindow:(NSWindow *)window {
  if (window.styleMask & NSWindowStyleMaskFullScreen) return 0;
  NSView *frame = window.contentView.superview;
  for (NSString *name in @[ @"cornerRadius", @"_cornerRadius" ]) {
    SEL selector = NSSelectorFromString(name);
    if (![frame respondsToSelector:selector]) continue;
    CGFloat radius = reinterpret_cast<CGFloat (*)(id, SEL)>(objc_msgSend)(frame, selector);
    if (std::isfinite(radius) && radius > 0) return radius;
  }
  SEL rounded = NSSelectorFromString(@"roundedCornerRadius");
  if ([frame respondsToSelector:rounded]) {
    float radius = reinterpret_cast<float (*)(id, SEL)>(objc_msgSend)(frame, rounded);
    if (std::isfinite(radius) && radius > 0) return radius;
  }
  return 0;
}

+ (NSWindow *)makeWindowForProfile:(NSString *)profile {
  if (!ArdiaHost.isStarted) return nil;
  ArdiaCoreWindow *coreWindow = [[ArdiaCoreWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1360, 860)];
  NSWindow *window = coreWindow.window;
  if (!window) return nil;
  ConfigureWindow(window);
  ArdiaWindowController *controller = [[ArdiaWindowController alloc] initWithCoreWindow:coreWindow];
  [Controllers() setObject:controller forKey:window];
  [self showProfile:profile ?: @"" inWindow:window];
  return window;
}

+ (NSWindow *)makeWindowForProfile:(NSString *)profile chromeWindow:(NSString *)chromeWindow {
  ArdiaWindowController *made = [ArdiaWindowController claimChromeMadeWindow:chromeWindow];
  if (!made) return [self makeWindowForProfile:profile];
  NSWindow *window = made.coreWindow.window;
  [self showProfile:profile ?: @"" inWindow:window];
  return window;
}

+ (NSWindow *)makeWindowForProfile:(NSString *)profile chromeWindow:(NSString *)chromeWindow appWindow:(NSString *)appWindow {
  const BOOL link = [appWindow hasPrefix:@"link:"];
  NSWindow *window = chromeWindow.length ? nil
                     : link ? [ArdiaEarlyWindow claimLittleWindowForLink:appWindow profile:profile]
                            : [ArdiaEarlyWindow claimForAppWindow:appWindow profile:profile];
  if (window) [self showProfile:profile ?: @"" inWindow:window];
  else window = [self makeWindowForProfile:profile chromeWindow:chromeWindow];
  if (window && appWindow.length && !link) [ArdiaWindowController forNSWindow:window].appWindowId = appWindow;
  return window;
}

+ (void)floatForWindowManagers:(NSWindow *)window {
  if (!window) return;
  objc_setAssociatedObject(window, kFloatsForWindowManagersKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  AnswerFloatingSubrole(window.class);
}

+ (void)floatOverActiveSpace:(NSWindow *)window {
  if (!window) return;
  ardia_pip::FloatOverActiveSpace(window);
}

+ (void)recordLaunchLayout {
  [ArdiaEarlyWindow recordNow];
}

+ (void)forgetLaunchPictures {
  [ArdiaEarlyWindow forgetPicturesNow];
}

+ (BOOL)takeDismissedAppWindow:(NSString *)appWindow {
  return [ArdiaEarlyWindow takeDismissed:appWindow];
}

+ (void)showProfile:(NSString *)profile inWindow:(NSWindow *)window {
  [self showProfile:profile inWindow:window report:nil];
}

+ (void)showProfile:(NSString *)profile
           inWindow:(NSWindow *)window
             report:(void (^)(BOOL, double, double, BOOL))report {
  ArdiaWindowController *controller = [ArdiaWindowController forNSWindow:window];
  if (!controller) return;
  const CFTimeInterval started = CACurrentMediaTime();
  const BOOL profileLoaded = ardia_host::LoadedProfile(profile ?: @"") != nil;
  __weak ArdiaCoreWindow *coreWindow = controller.coreWindow;
  __weak ArdiaWindowController *weakController = controller;
  ardia_host::WithProfile(profile ?: @"", ^(ArdiaCoreProfile *p) {
    ArdiaWindowController *shown = weakController;
    if (!p || !coreWindow || !shown) return;
    coreWindow.activeProfile = p;
    ardia_host::NoteProfileSwitch(p, coreWindow.window);
    const double activeMs = (CACurrentMediaTime() - started) * 1000;
    ArdiaCoreTab *tab = [ArdiaTabStrip activeTabInWindow:shown profile:p];
    ArdiaWebView *view = tab ? [ArdiaTabRegistry viewForTab:tab] : nil;
    NSWindow *shownWindow = coreWindow.window;
    if (report) {
      void (^shownFirstFrame)(BOOL) = ^(BOOL heldTimedOut) {
        report(profileLoaded, activeMs, (CACurrentMediaTime() - started) * 1000, heldTimedOut);
      };
      if (view && shownWindow && view.window == shownWindow && [[coreWindow tabsForProfile:p] containsObject:tab])
        [view reportSwapShown:shownFirstFrame];
    }
    if (view && shownWindow && view.window == shownWindow && [[coreWindow tabsForProfile:p] containsObject:tab])
      [view requestFocusRestoreIn:shownWindow];
  });
}

+ (void)prepareProfiles:(NSArray<NSString *> *)profiles forWindow:(NSWindow *)window {
  ArdiaWindowController *controller = [ArdiaWindowController forNSWindow:window];
  if (!controller) return;
  __weak ArdiaCoreWindow *coreWindow = controller.coreWindow;
  for (NSString *profile in profiles)
    ardia_host::WithProfile(profile, ^(ArdiaCoreProfile *p) {
      if (p && coreWindow) [coreWindow prepareProfile:p];
    });
}

+ (void)setTrafficLightsCenter:(NSValue *)center trailing:(BOOL)trailing inWindow:(NSWindow *)window {
  const BOOL translated = objc_getAssociatedObject(window, kLightsShownKey) != nil;
  NSValue *current = objc_getAssociatedObject(window, kLightsCenterKey);
  const BOOL placed = ArdiaTrafficLightsTrailing(window) == trailing && (current == center || [current isEqual:center]);
  if (placed && !translated) return;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (translated) {
    objc_setAssociatedObject(window, kLightsShownKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kLightsMoveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TranslateTrafficLights(window, 0);
    TuckTrafficLightsOutsideWindow(window);
  }
  if (!placed) {
    objc_setAssociatedObject(window, kLightsTrailingKey, trailing ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kLightsCenterKey, center, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RetileTrafficLights(window);
  }
  [CATransaction commit];
}

+ (void)moveTrafficLightsCenter:(NSValue *)center trailing:(BOOL)trailing inWindow:(NSWindow *)window {
  if (ArdiaTrafficLightsTrailing(window) != trailing) return [self setTrafficLightsCenter:center trailing:trailing inWindow:window];
  id shown = objc_getAssociatedObject(window, kLightsShownKey);
  NSValue *current = shown ? (shown == NSNull.null ? nil : shown) : objc_getAssociatedObject(window, kLightsCenterKey);
  if (current == center || [current isEqual:center]) return;
  if (!MoveTrafficLights(window, center)) [self setTrafficLightsCenter:center trailing:trailing inWindow:window];
}

+ (void)insetTrafficLightsOfWindow:(NSWindow *)window {
  if (window) InsetUtilityTrafficLights(window);
}

+ (NSSize)windowSizeFromInterfaceSize:(NSSize)size forWindow:(NSWindow *)window {
  return InterfaceSize(size, window);
}

+ (void)setInterfaceMinSize:(NSSize)size ofWindow:(NSWindow *)window {
  if (!window) return;
  FollowInterfaceScale();
  objc_setAssociatedObject(window, kInterfaceMinSizeKey, [NSValue valueWithSize:size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  ApplyInterfaceMinSize(window, YES);
}

+ (void)keepInterfaceContentSizeOfWindow:(NSWindow *)window {
  if (!window) return;
  FollowInterfaceScale();
  objc_setAssociatedObject(window, kInterfaceContentScaleKey, @(ArdiaInterfaceScale.scale), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (void)setSwappedHandler:(void (^)(NSWindow *, NSWindow *))handler {
  gSwapped = [handler copy];
}

+ (void (^)(NSWindow *, NSWindow *))swappedHandler {
  return gSwapped;
}

+ (void)closeWindow:(NSWindow *)window {
  ArdiaWindowController *controller = [ArdiaWindowController forNSWindow:window];
  if (![ArdiaWebView keepTransfersOfWindow:window]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [ArdiaChromeWindowHost closeWindow:window];
    });
    return;
  }
  if (controller) [controller.coreWindow close];
  else [window close];
}

+ (BOOL)windowIsFullScreen:(NSWindow *)window {
  return IsWindowFullScreen(window);
}

+ (BOOL)windowFullScreenIsForPage:(NSWindow *)window {
  return [objc_getAssociatedObject(window, kWindowFullScreenKey) enteredForPage];
}

+ (BOOL)userSeesWindow:(NSWindow *)window {
  return [ArdiaWindowController userSees:window];
}

+ (BOOL)userSeesOnlyThroughWindowServer:(NSWindow *)window {
  return [ArdiaWindowController userSeesOnlyThroughWindowServer:window];
}

+ (void)reconsiderSightOfWindow:(NSWindow *)window {
  [ArdiaWindowController reconsiderSightOf:window];
}

+ (void)setPlaysForAutoPictureInPictureHandler:(BOOL (^)(NSWindow *))handler {
  gPlaysForAutoPictureInPicture = [handler copy];
}

+ (BOOL (^)(NSWindow *))playsForAutoPictureInPictureHandler {
  return gPlaysForAutoPictureInPicture;
}

+ (void)setShouldCloseHandler:(BOOL (^)(NSWindow *))handler {
  gShouldClose = [handler copy];
}

+ (BOOL (^)(NSWindow *))shouldCloseHandler {
  return gShouldClose;
}

+ (BOOL)windowShouldClose:(NSWindow *)window {
  return gShouldClose ? gShouldClose(window) : YES;
}

+ (void)setRefusesUnhandledKeyHandler:(BOOL (^)(NSWindow *, NSEvent *))handler {
  gRefusesUnhandledKey = [handler copy];
}

+ (BOOL (^)(NSWindow *, NSEvent *))refusesUnhandledKeyHandler {
  return gRefusesUnhandledKey;
}

+ (void)setFocusHandoffSummaryHandler:(NSString *(^)(NSWindow *))handler {
  gFocusHandoffSummary = [handler copy];
}

+ (NSString *(^)(NSWindow *))focusHandoffSummaryHandler {
  return gFocusHandoffSummary;
}

+ (void)embedRootView:(NSView *)root inWindow:(NSWindow *)window {
  ArdiaWindowController *controller = [ArdiaWindowController forNSWindow:window];
  if (!controller) return;
  NSView *host = controller.coreWindow.hostView;
  root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  root.frame = host.bounds;
  NSView *cover = [ArdiaEarlyWindow coverInWindow:window];
  if (cover.superview == host) [host addSubview:root positioned:NSWindowBelow relativeTo:cover];
  else [host addSubview:root];
  controller.root = root;
  [ArdiaInterfaceScale rootAttached:root];
  [ArdiaEarlyWindow rootEmbedded:root inWindow:window];
}

+ (NSView *)embeddedRootOfWindow:(NSWindow *)window {
  return [ArdiaCoreWindow embeddedRootOfWindow:window];
}

+ (Class)contentViewClass {
  return ArdiaCoreWindow.contentViewClass;
}

+ (NSView *)rootViewOfWindow:(NSWindow *)window {
  return [ArdiaWindowController forNSWindow:window].root;
}

+ (void)removeRootViewOfWindow:(NSWindow *)window {
  ArdiaWindowController *controller = [ArdiaWindowController forNSWindow:window];
  [controller.root removeFromSuperview];
  controller.root = nil;
}

@end
