#import "ArdiaHiddenPage.h"

#import "ArdiaEngineBridge.h"
#import "ArdiaInternal.h"
#import "ArdiaLaunchConfig.h"
#import "ArdiaServices.h"
#import "ArdiaTabParking.h"

namespace {

constexpr CGFloat kSheetWidth = 520;
constexpr CGFloat kSheetHeight = 660;
constexpr CGFloat kBarHeight = 52;

NSWindow *SheetParent() {
  if (NSApp.mainWindow.isVisible) return NSApp.mainWindow;
  if (NSApp.keyWindow.isVisible) return NSApp.keyWindow;
  for (NSWindow *window in NSApp.orderedWindows)
    if (window.isVisible && !window.isSheet && [ArdiaWindowController forNSWindow:window]) return window;
  return nil;
}

NSCountedSet<NSString *> *BlockedDownloadOrigins() {
  static NSCountedSet *origins = [NSCountedSet set];
  return origins;
}

bool IsBlockedDownload(NSString *url, NSString *mimeType) {
  if (![url isKindOfClass:NSString.class]) return false;
  if (!BlockedDownloadOrigins().count) return false;
  NSString *lower = url.lowercaseString;
  if ([lower hasPrefix:@"data:text/csv"]) return true;
  bool csv = [mimeType isKindOfClass:NSString.class] && [mimeType.lowercaseString hasPrefix:@"text/csv"];
  if (csv && [lower hasPrefix:@"blob:null/"]) return true;
  for (NSString *origin in BlockedDownloadOrigins())
    if ([url hasPrefix:[@"blob:" stringByAppendingString:origin]]) return true;
  return false;
}

void WatchBlockedDownloads() {
  static bool watching = false;
  if (watching) return;
  watching = true;
  [ArdiaEngineBridge observe:@"downloads.changed"
                      handler:^(NSDictionary *payload) {
                        NSDictionary *download = [payload[@"download"] isKindOfClass:NSDictionary.class] ? payload[@"download"] : nil;
                        NSString *downloadId = [download[@"id"] isKindOfClass:NSString.class] ? download[@"id"] : nil;
                        if (!downloadId) return;
                        if (!IsBlockedDownload(download[@"url"], download[@"mimeType"])) {
                          if (BlockedDownloadOrigins().count)
                            NSLog(@"[vaults] download during a hidden page export was not blocked: %@", [download[@"url"] description].length > 48 ? [[download[@"url"] description] substringToIndex:48] : download[@"url"]);
                          return;
                        }
                        NSString *state = [download[@"state"] isKindOfClass:NSString.class] ? download[@"state"] : @"";
                        NSLog(@"[vaults] hidden page download blocked (%@)", state);
                        if ([state isEqualToString:@"downloading"]) return [ArdiaServices downloadCommand:@"cancel" id:downloadId];
                        NSString *path = [download[@"path"] isKindOfClass:NSString.class] ? download[@"path"] : @"";
                        if ([state isEqualToString:@"finished"] && path.length) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                        [ArdiaServices downloadCommand:@"remove" id:downloadId];
                      }];
}

}

@interface ArdiaHiddenPage () <ArdiaParkedPageHolder>
@end

@implementation ArdiaHiddenPage {
  ArdiaCoreTab *_tab;
  NSString *_config;
  NSPanel *_panel;
  void (^_dismissed)(void);
  BOOL _closedByChrome;
  NSString *_blockedOrigin;
}

+ (instancetype)openURL:(NSString *)url profile:(NSString *)profileName config:(NSString *)configJSON {
  if (!ArdiaHost.isStarted || !url.length) return nil;
  if (ardia_host::IsPrivateProfile(profileName) || ardia_host::IsDeletedProfile(profileName ?: @"")) return nil;
  ArdiaCoreProfile *profile = ardia_host::LoadedProfile(profileName ?: @"");
  if (!profile) return nil;
  ArdiaWindowController *keeper = [ArdiaWindowController strayWindowForProfile:profile];
  if (!keeper) return nil;
  keeper.hostChanges++;
  ArdiaCoreTab *tab = [keeper.coreWindow openTab:url profile:profile foreground:NO];
  keeper.hostChanges--;
  if (!tab) {
    [keeper.coreWindow close];
    return nil;
  }
  ArdiaHiddenPage *page = [ArdiaHiddenPage new];
  page->_tab = tab;
  page->_config = [configJSON copy] ?: @"{}";
  [ArdiaTabParking keepOffscreen:tab holder:page];
  [tab deliverHeldPageMessages];
  return page;
}

- (BOOL)closedByChrome {
  return _closedByChrome;
}

- (BOOL)closed {
  return !_tab || _tab.closed;
}

- (NSString *)url {
  return _tab.url ?: @"";
}

- (BOOL)revealed {
  return _panel != nil;
}

- (void)blockDownloadsFrom:(NSString *)origin {
  if (self.closed || _blockedOrigin || !origin.length) return;
  _blockedOrigin = [origin copy];
  [BlockedDownloadOrigins() addObject:_blockedOrigin];
  WatchBlockedDownloads();
}

- (void)load:(NSString *)url {
  if (!self.closed) [_tab loadURL:url userInitiated:NO];
}

- (void)evaluate:(NSString *)code completion:(void (^)(NSString *))completion {
  if (self.closed) return completion(nil);
  [_tab evaluate:code completion:completion];
}

- (void)send:(NSString *)kind json:(NSString *)json {
  if (!self.closed) [_tab callPage:kind json:json];
}

- (void)tab:(ArdiaCoreTab *)tab
    didReceivePageMessage:(NSString *)kind
                     json:(NSString *)json
                    frame:(NSString *)frameId
                     main:(BOOL)main
                   origin:(NSString *)origin {
  if ([kind isEqualToString:@"hello"] && frameId.length) [tab callFrame:frameId kind:@"config" json:main ? _config : @"{}"];
  if (main && _onMessage) _onMessage(kind ?: @"", json ?: @"null", origin ?: @"", main);
}

- (void)tabDidCommitDocument:(ArdiaCoreTab *)tab {
  if (_onCommit) _onCommit(tab.url ?: @"");
}

- (void)tab:(ArdiaCoreTab *)tab didFailLoad:(NSString *)url code:(int)code description:(NSString *)text {
  if (_onFail) _onFail(url ?: @"", code);
}

- (void)tab:(ArdiaCoreTab *)tab rendererGone:(NSString *)status code:(int)code {
  if (_onFail) _onFail(tab.url ?: @"", -1);
}

- (void)tabWillClose:(ArdiaCoreTab *)tab {
  _closedByChrome = YES;
  [self finish];
}

- (BOOL)revealWithTitle:(NSString *)title onDismiss:(void (^)(void))dismissed {
  if (self.closed) return NO;
  if (ArdiaLaunchConfig.shared.background) {
    NSLog(@"[vaults] google page reveal in a hidden test instance, not shown: %@", title);
    return NO;
  }
  if (_panel) {
    [_panel orderFront:nil];
    return YES;
  }
  _dismissed = [dismissed copy];
  NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, kSheetWidth, kSheetHeight)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
  panel.title = title;
  panel.releasedWhenClosed = NO;
  NSView *content = panel.contentView;
  NSView *page = _tab.view;
  [page removeFromSuperview];
  page.frame = NSMakeRect(0, kBarHeight, kSheetWidth, kSheetHeight - kBarHeight);
  page.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [content addSubview:page];
  NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(dismissPressed:)];
  cancel.keyEquivalent = @"\e";
  [cancel sizeToFit];
  cancel.frame = NSMakeRect(kSheetWidth - NSWidth(cancel.frame) - 20, (kBarHeight - NSHeight(cancel.frame)) / 2, NSWidth(cancel.frame),
                            NSHeight(cancel.frame));
  cancel.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
  [content addSubview:cancel];
  _panel = panel;
  [_tab noteShownByHost:YES];
  if (NSWindow *parent = SheetParent()) {
    [parent beginSheet:panel completionHandler:nil];
  } else {
    [panel center];
    [panel makeKeyAndOrderFront:nil];
  }
  [_tab focus];
  return YES;
}

- (void)dismissPressed:(id)sender {
  void (^dismissed)(void) = _dismissed;
  [self conceal];
  if (dismissed) dismissed();
}

- (void)conceal {
  NSPanel *panel = _panel;
  _panel = nil;
  _dismissed = nil;
  if (!panel) return;
  if (panel.sheetParent) [panel.sheetParent endSheet:panel];
  [panel orderOut:nil];
  if (_tab && !_tab.closed) {
    [_tab noteShownByHost:NO];
    [ArdiaTabParking keepOffscreen:_tab holder:self];
  }
}

- (void)close {
  ArdiaCoreTab *tab = _tab;
  [self conceal];
  [self finish];
  if (tab && !tab.closed) [tab closeNow];
}

- (void)finish {
  ArdiaCoreTab *tab = _tab;
  if (!tab) return;
  _tab = nil;
  if (_blockedOrigin) {
    NSString *origin = _blockedOrigin;
    _blockedOrigin = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [BlockedDownloadOrigins() removeObject:origin];
    });
  }
  if (tab.delegate == self) tab.delegate = nil;
  if ([ArdiaTabParking takeHolderOfTab:tab] != self) NSLog(@"[vaults] hidden page had another holder");
  void (^closed)(void) = _onClosed;
  _onClosed = nil;
  _onMessage = nil;
  _onCommit = nil;
  _onFail = nil;
  if (closed) closed();
}

@end
