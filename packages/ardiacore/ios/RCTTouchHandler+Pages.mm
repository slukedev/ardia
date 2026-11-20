#import "ArdiaWebViewInternal.h"

#import <React/RCTTouchHandler.h>

@protocol ArdiaPressablePage
- (void)notePagePress;
@end

@implementation RCTTouchHandler (Pages)

- (BOOL)gestureRecognizer:(NSGestureRecognizer *)recognizer shouldAttemptToRecognizeWithEvent:(NSEvent *)event {
  if (event.type != NSEventTypeLeftMouseDown) return YES;
  for (NSView *view = [event.window.contentView.superview hitTest:event.locationInWindow]; view && view != recognizer.view; view = view.superview)
    if ([view isKindOfClass:ArdiaWebView.class]) {
      [(ArdiaWebView *)view showHeldPage:ArdiaHeldPageEnd::Pressed];
      [(ArdiaWebView *)view emit:@"pagePress" payload:@{}];
      return NO;
    } else if ([view respondsToSelector:@selector(notePagePress)]) {
      [(id<ArdiaPressablePage>)view notePagePress];
      return NO;
    }
  return YES;
}

@end
