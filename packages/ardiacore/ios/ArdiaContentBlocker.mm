#import "ArdiaContentBlockerInternal.h"

#include <utility>

using namespace ardia_content_blocker;

namespace ardia_content_blocker {

NSString *ExtensionId() { return @"fajbdaomknpkicfjcpipdmcpoamdmilh"; }

NSString *const kLiteId = @"bnjeokpoejhioagiokhkhmdogkhbnbki";

}

namespace {

NSString *const kBundledName = @"ublock";

}

namespace ardia_content_blocker {

NSString *const kLiteReaderName = @"ublock-lite-settings";

NSString *const kLiteMovedMarker = @"uBlock Origin Lite settings moved";

bool gFailNextMessage = false;

}

namespace {

double gDelayNextLoadMs = 0;

NSString *BundledExtension() {
  NSString *bundled = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[@"Extensions" stringByAppendingPathComponent:kBundledName]];
  return [NSFileManager.defaultManager fileExistsAtPath:[bundled stringByAppendingPathComponent:@"manifest.json"]] ? bundled : nil;
}

NSString *gExtensionPath;

void StartPreparing() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gExtensionPath = BundledExtension();
    NSString *oldCopies = [[ArdiaHost.dataDirectory stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Built-in Extensions"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      if ([NSFileManager.defaultManager fileExistsAtPath:oldCopies]) [NSFileManager.defaultManager removeItemAtPath:oldCopies error:nil];
    });
  });
}

NSString *ExtensionPath() {
  StartPreparing();
  return gExtensionPath;
}

void FollowDefault(NSArray<NSString *> *profiles, void (^done)(NSString *error));

NSMapTable<NSString *, ArdiaCoreProfile *> *LoadedInto() {
  static NSMapTable *profiles = [NSMapTable strongToWeakObjectsMapTable];
  return profiles;
}

void WhenDefaultSettled(void (^then)(void));

}

namespace ardia_content_blocker {

void ForgetIfGone(NSString *profile) {
  if (![LoadedProfiles() containsObject:profile]) return;
  ArdiaCoreProfile *now = ardia_host::LoadedProfile(profile);
  if (now && now == [LoadedInto() objectForKey:profile] && !ardia_host::IsDeletedProfile(profile)) return;
  [LoadedProfiles() removeObject:profile];
  [LoadedInto() removeObjectForKey:profile];
  [Pages()[profile] fail:@"profile gone"];
  [Pages() removeObjectForKey:profile];
}

void LoadIntoProfile(NSString *profile, void (^then)(NSString *error)) {
  then = [then copy];
  StartPreparing();
  void (^load)(void) = ^{
    if ([LoadedProfiles() containsObject:profile]) return then(nil);
    ardia_host::WithProfile(profile, ^(ArdiaCoreProfile *p) {
      if ([LoadedProfiles() containsObject:profile]) return then(nil);
      NSString *path = gExtensionPath;
      if (!p || !path) return then(@"not loaded");
      NSString *loaded = [p loadComponentExtension:path];
      if (![loaded isEqualToString:ExtensionId()]) {
        NSLog(@"[blocker] component load failed (%@)", loaded);
        return then(@"not loaded");
      }
      [LoadedProfiles() addObject:profile];
      [LoadedInto() setObject:p forKey:profile];
      then(nil);
    });
  };
  if (NSThread.isMainThread) load();
  else dispatch_async(dispatch_get_main_queue(), load);
}

NSString *const kOffDirective = @"/^(?:ardia-blocking-off|)/";

}

namespace {

bool gDefaultSettled = false;

bool gLaunching = true;

constexpr double kSettleAfterLaunchSeconds = 1.5;

NSString *const kRead =
    @"Promise.all([lists(), trusted()]).then(([l, t]) => ({lists: selected(l).sort(), imported: imported(l), whitelist: [...t.whitelist].sort(), autoUpdate: l.autoUpdate !== false}))";

NSString *const kFollow =
    @"Promise.all([lists(), trusted()]).then(([l, t]) => {"
     "  const want = %@;"
     "  if (!Array.isArray(want.lists) || !Array.isArray(want.whitelist)) throw new Error('no settings to copy');"
     "  const mine = imported(l);"
     "  const wanted = Array.isArray(want.imported) ? want.imported : mine;"
     "  const toImport = wanted.filter((u) => !mine.includes(u));"
     "  const toRemove = mine.filter((u) => !wanted.includes(u));"
     "  const importsDiffer = toImport.length > 0 || toRemove.length > 0;"
     "  let written = Promise.resolve(null);"
     "  if (importsDiffer)"
     "    written = written.then(() => send({what: 'applyFilterListSelection', toImport: toImport.join('\\n'), toRemove}));"
     "  if (importsDiffer || !sameSet(selected(l), want.lists))"
     "    written = written.then(() => applyLists(want.lists));"
     "  if (!sameSet(t.whitelist, want.whitelist))"
     "    written = written.then(() => send({what: 'setWhitelist', whitelist: want.whitelist.join('\\n')}));"
     "  if ((l.autoUpdate !== false) !== (want.autoUpdate !== false))"
     "    written = written.then(() => send({what: 'userSettings', name: 'autoUpdate', value: want.autoUpdate !== false}));"
     "  return written.then(() => null);"
     "})";

void ForgetGoneProfiles() {
  NSArray<NSString *> *loaded = [LoadedProfiles().array copy];
  for (NSString *profile in loaded) ForgetIfGone(profile);
}

void FollowDefault(NSArray<NSString *> *profiles, void (^done)(NSString *error)) {
  done = [done copy];
  if (!gDefaultSettled && ArdiaHost.isStarted) return WhenDefaultSettled(^{ FollowDefault(profiles, done); });
  if (!profiles) ForgetGoneProfiles();
  profiles = [(profiles ?: LoadedProfiles().array) filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
  if (!profiles.count) return done(nil);
  Call(kProfile, kRead, ^(NSDictionary *settings, NSString *error) {
    if (error) return done(error);
    if (![settings isKindOfClass:NSDictionary.class]) return done(@"no settings to copy");
    dispatch_group_t group = dispatch_group_create();
    __block NSString *failed;
    for (NSString *profile in profiles) {
      dispatch_group_enter(group);
      Call(profile, ScriptWith(kFollow, @[ settings ]), ^(id, NSString *error) {
        const bool gone = !ardia_host::LoadedProfile(profile) || ardia_host::IsDeletedProfile(profile);
        if (!gone) failed = failed ?: error;
        dispatch_group_leave(group);
      }, false);
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{ done(failed); });
  });
}

NSMutableArray<void (^)(void)> *SettledWaiters() {
  static NSMutableArray *waiters = [NSMutableArray array];
  return waiters;
}

void WhenDefaultSettled(void (^then)(void)) {
  if (gDefaultSettled) return then();
  [SettledWaiters() addObject:[then copy]];
}

void DefaultSettled() {
  gDefaultSettled = true;
  gLaunching = false;
  NSArray<void (^)(void)> *waiters = [SettledWaiters() copy];
  [SettledWaiters() removeAllObjects];
  for (void (^waiter)(void) in waiters) waiter();
}

constexpr int kInheritAttempts = 6;

void Inherit(NSString *profile, int attempt, void (^first)(NSString *error)) {
  first = [first copy];
  FollowDefault(@[ profile ], ^(NSString *error) {
    if (first) first(error);
    const bool gone = !ardia_host::LoadedProfile(profile) || ardia_host::IsDeletedProfile(profile) ||
                      ![LoadedProfiles() containsObject:profile];
    if (!error || gone || attempt + 1 >= kInheritAttempts) {
      if (error && !gone) NSLog(@"[blocker] profile \"%@\" didn't take the default profile's settings: %@", profile, error);
      return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1 << attempt) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      Inherit(profile, attempt + 1, nil);
    });
  });
}

void LoadHeld(NSString *profile) {
  ForgetGoneProfiles();
  ArdiaCoreProfile *p = ardia_host::LoadedProfile(profile);
  const bool isDefault = profile.length == 0;
  const bool firstLoad = p && ![LoadedProfiles() containsObject:profile];
  const bool hold = firstLoad && (isDefault ? LiteSettingsPending(p) : !gLaunching);
  if (hold) [p holdNavigationsUntilRulesetsOf:ExtensionId()];
  void (^release)(NSString *) = ^(NSString *why) {
    if (!hold) return;
    if (!why) [p releaseNavigationHoldReady];
    else [p releaseNavigationHold:why ?: @"uBlock Origin is ready"];
  };
  void (^load)(void) = ^{
    LoadIntoProfile(profile, ^(NSString *error) {
      if (error) {
        if (isDefault) DefaultSettled();
        return release([@"the content blocker didn't load: " stringByAppendingString:error]);
      }
      if (!isDefault) {
        return WhenDefaultSettled(^{
          Inherit(profile, 0, ^(NSString *followError) {
            release(followError ? [@"the default profile's settings didn't apply: " stringByAppendingString:followError] : nil);
          });
        });
      }
      void (^settle)(void) = ^{
        ArdiaCoreProfile *current = ardia_host::LoadedProfile(profile);
        if (!hold && current && !LiteSettingsPending(current)) return DefaultSettled();
        Call(profile, @"null", ^(id, NSString *readyError) {
          ArdiaCoreProfile *loaded = ardia_host::LoadedProfile(profile);
          if (readyError || !loaded) {
            DefaultSettled();
            return release(readyError ? [@"uBlock Origin isn't ready: " stringByAppendingString:readyError] : nil);
          }
          MoveLiteSettings(profile, loaded, ^{
            DefaultSettled();
            release(nil);
          });
        });
      };
      if (hold || !gLaunching) return settle();
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSettleAfterLaunchSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), settle);
    });
  };
  const double delay = std::exchange(gDelayNextLoadMs, 0);
  if (delay > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)), dispatch_get_main_queue(), load);
  else load();
}

NSString *Category(NSString *listId, NSString *group) {
  if ([group isEqual:@"custom"]) return @"custom";
  if ([group isEqual:@"regions"]) return @"regional";
  if ([listId containsString:@"cookie"]) return @"cookies";
  if ([group isEqual:@"privacy"] || [listId isEqual:@"ublock-privacy"]) return @"trackers";
  if ([group isEqual:@"malware"] || [listId isEqual:@"ublock-badware"]) return @"security";
  if ([group isEqual:@"annoyances"] || [group isEqual:@"social"]) return @"annoyances";
  return @"ads";
}

double Count(id value) { return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0; }

NSString *BundledVersion() {
  NSString *path = [ExtensionPath() stringByAppendingPathComponent:@"manifest.json"];
  NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
  NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![manifest isKindOfClass:NSDictionary.class]) return @"";
  for (NSString *key in @[ @"version_name", @"version" ])
    if ([manifest[key] isKindOfClass:NSString.class]) return manifest[key];
  return @"";
}

NSString *const kState =
    @"Promise.all([lists(), trusted(), fetch('/assets/assets.json').then((r) => r.json())]).then(([l, t, assets]) => {"
     "  const langs = new Set([chrome.i18n.getUILanguage(), ...(navigator.languages || [])].map((x) => (/^[a-z]+/.exec(x) || [])[0]).filter(Boolean));"
     "  const forLanguages = (lang) => typeof lang === 'string' && lang.split(/\\s+/).some((x) => langs.has(x));"
     "  const onByDefault = (id) => !!assets[id] && (assets[id].off !== true || forLanguages(assets[id].lang));"
     "  return {"
     "    lists: Object.entries(l.available)"
     "      .filter(([id, list]) => list && list.content === 'filters' && list.group !== 'user')"
     "      .map(([id, list]) => ({id, title: list.title || id, group: list.group || '', enabled: list.off !== true,"
     "        defaultOn: list.group !== 'custom' && onByDefault(id), filters: list.entryCount || 0,"
     "        failed: !!(l.cache && l.cache[id] && l.cache[id].error !== undefined)})),"
     "    networkFilters: l.netFilterCount || 0,"
     "    cosmeticFilters: l.cosmeticFilterCount || 0,"
     "    enabled: !t.whitelist.includes(offDirective),"
     "    allowedHosts: t.whitelist.filter((d) => !d.includes('/') && !d.startsWith('#') && !(t.whitelistDefault || []).includes(d)),"
     "  };"
     "})";

void Publish(NSDictionary *change) {
  [NSNotificationCenter.defaultCenter postNotificationName:@"ArdiaContentBlockerDidChange" object:nil userInfo:change];
}

void State(void (^completion)(NSDictionary *state)) {
  completion = [completion copy];
  if (!gDefaultSettled && ArdiaHost.isStarted) return WhenDefaultSettled(^{ State(completion); });
  Call(kProfile, kState, ^(NSDictionary *read, NSString *error) {
    if (![read isKindOfClass:NSDictionary.class] || ![read[@"lists"] isKindOfClass:NSArray.class]) {
      return completion(@{
        @"enabled" : @NO, @"lists" : @[], @"allowedHosts" : @[], @"version" : BundledVersion(),
        @"stats" : @{@"ready" : @NO, @"enabled" : @NO, @"parseMs" : @0, @"lookups" : @0, @"averageLookupMicros" : @0,
                     @"maxLookupMicros" : @0, @"error" : error ?: @"unavailable"},
      });
    }
    NSMutableArray *lists = [NSMutableArray array];
    for (NSDictionary *l in read[@"lists"]) {
      if (![l isKindOfClass:NSDictionary.class] || ![l[@"id"] isKindOfClass:NSString.class]) continue;
      [lists addObject:@{
        @"id" : l[@"id"],
        @"title" : [l[@"title"] isKindOfClass:NSString.class] ? l[@"title"] : l[@"id"],
        @"category" : Category(l[@"id"], [l[@"group"] isKindOfClass:NSString.class] ? l[@"group"] : @""),
        @"enabled" : @([l[@"enabled"] boolValue]),
        @"defaultOn" : @([l[@"defaultOn"] boolValue]),
        @"filters" : @(Count(l[@"filters"])),
        @"failed" : @([l[@"failed"] boolValue]),
      }];
    }
    NSMutableArray *allowed = [NSMutableArray array];
    for (NSString *host in [read[@"allowedHosts"] isKindOfClass:NSArray.class] ? read[@"allowedHosts"] : @[])
      if ([host isKindOfClass:NSString.class]) [allowed addObject:host];
    const BOOL on = [read[@"enabled"] boolValue];
    NSMutableArray *chosen = [NSMutableArray array];
    for (NSDictionary *l in lists)
      if ([l[@"enabled"] boolValue]) [chosen addObject:l[@"id"]];
    Publish(@{@"enabled" : @(on), @"lists" : chosen, @"allowedHosts" : allowed});
    completion(@{
      @"enabled" : @(on),
      @"version" : BundledVersion(),
      @"lists" : lists,
      @"allowedHosts" : allowed,
      @"stats" : @{
        @"ready" : @YES, @"enabled" : @(on), @"networkFilters" : @(Count(read[@"networkFilters"])),
        @"cosmeticFilters" : @(Count(read[@"cosmeticFilters"])), @"parseMs" : @0, @"lookups" : @0,
        @"averageLookupMicros" : @0, @"maxLookupMicros" : @0,
      },
    });
  });
}

void Changed(NSString *error, void (^completion)(NSString *error)) {
  if (error) return completion(error);
  completion = [completion copy];
  FollowDefault(nil, ^(NSString *followError) {
    State(^(NSDictionary *state) { [ArdiaEvents emit:@"contentBlocker.changed" data:state[@"stats"]]; });
    completion(followError);
  });
}

void ListsChanged(NSString *error, void (^completion)(NSString *error)) {
  if (error) return completion(error);
  completion(nil);
  State(^(NSDictionary *state) { [ArdiaEvents emit:@"contentBlocker.changed" data:state[@"stats"]]; });
  FollowDefault(nil, ^(NSString *followError) {
    if (followError) NSLog(@"[blocker] the other profiles didn't take the list change: %@", followError);
  });
}

}

namespace ardia_host {

void PrepareContentBlocker() {
  StartPreparing();
}

void LoadContentBlocker(NSString *profile) {
  if (!IsPrivateProfile(profile)) LoadHeld(profile ?: @"");
}

}

namespace {

NSString *const kHidingRules =
    @"const hidingRule = /^[a-z0-9.-]+##[^+^\\s][^\\n{}]*$/;"
     "const userFilters = () => chrome.extension.getBackgroundPage().µBlock.loadUserFilters().then((d) => {"
     "  if (!d || d.error || typeof d.content !== 'string') throw new Error(`user filters: ${d && d.error || 'unreadable'}`);"
     "  return d.content;"
     "});";

NSString *const kReadHidden = @"userFilters().then((content) => content.split('\\n').map((l) => l.trim()).filter((l) => hidingRule.test(l)))";

NSString *const kHide =
    @"Promise.resolve(%@).then((want) => {"
     "  for (const f of want) {"
     "    if (typeof f !== 'string' || f.length > 1024 || !hidingRule.test(f)) throw new Error('not a hiding rule');"
     "    document.createDocumentFragment().querySelector(f.slice(f.indexOf('##') + 2));"
     "  }"
     "  return userFilters().then((content) => {"
     "    const have = new Set(content.split('\\n').map((l) => l.trim()));"
     "    const fresh = [...new Set(want)].filter((f) => !have.has(f));"
     "    const ublock = chrome.extension.getBackgroundPage().µBlock;"
     "    if (!ublock.selectedFilterLists.includes(ublock.userFiltersPath))"
     "      ublock.applyFilterListSelection({toSelect: [ublock.userFiltersPath], merge: true});"
     "    return fresh.length ? ublock.appendUserFilters(fresh.join('\\n'), {}) : null;"
     "  });"
     "}).then(() => null)";

NSString *const kRestore =
    @"Promise.resolve(new Set(%@)).then((drop) => userFilters().then((content) => {"
     "  const lines = content.split('\\n');"
     "  const kept = lines.filter((l) => !drop.has(l.trim()));"
     "  if (kept.length === lines.length) return null;"
     "  const ublock = chrome.extension.getBackgroundPage().µBlock;"
     "  return ublock.saveUserFilters(kept.join('\\n')).then(() => ublock.loadFilterLists());"
     "})).then(() => null)";

NSString *WithHidingRules(NSString *body) {
  return [NSString stringWithFormat:@"(() => { %@ return %@; })()", kHidingRules, body];
}

NSArray<NSString *> *Strings(id value) {
  NSMutableArray *out = [NSMutableArray array];
  if ([value isKindOfClass:NSArray.class])
    for (id item in value)
      if ([item isKindOfClass:NSString.class]) [out addObject:item];
  return out;
}

}

@implementation ArdiaContentBlocker

+ (void)state:(void (^)(NSDictionary<NSString *, id> *))completion {
  State(completion);
}

+ (void)setEnabled:(BOOL)enabled completion:(void (^)(NSString *))completion {
  NSString *script = @"trusted().then((t) => {"
                      "  const on = %@;"
                      "  const kept = t.whitelist.filter((d) => d !== offDirective);"
                      "  return send({what: 'setWhitelist', whitelist: (on ? kept : kept.concat([offDirective])).join('\\n')});"
                      "}).then(() => send({what: 'userSettings', name: 'autoUpdate', value: %@}))";
  Call(kProfile, ScriptWith(script, @[ @(enabled), @(enabled) ]), ^(id, NSString *error) {
    if (!error) Publish(@{@"enabled" : @(enabled)});
    Changed(error, completion);
  });
}

+ (void)setList:(NSString *)listId enabled:(BOOL)enabled completion:(void (^)(NSString *))completion {
  NSString *script = @"lists().then((l) => {"
                      "  const [id, on] = [%@, %@];"
                      "  if (!l.available[id]) throw new Error(`no list ${id}`);"
                      "  const keep = selected(l).filter((x) => x !== id);"
                      "  return applyLists(on ? keep.concat([id]) : keep);"
                      "})";
  Call(kProfile, ScriptWith(script, @[ listId, @(enabled) ]), ^(id, NSString *error) {
    if (!error) Publish(@{@"list" : listId, @"listEnabled" : @(enabled)});
    ListsChanged(error, completion);
  });
}

+ (void)addList:(NSString *)url completion:(void (^)(NSDictionary<NSString *, id> *, NSString *))completion {
  NSString *script = @"lists().then((before) => {"
                      "  const url = %@;"
                      "  if (!/^https?:\\/\\/[^\\s\\/]+\\S*$/i.test(url) || url.length > 2048) throw new Error('not a list address');"
                      "  const needle = url.replace(/^https?:/i, '');"
                      "  const findId = (l) => l.available[url] ? url : Object.keys(l.available).find((k) =>"
                      "    [].concat(l.available[k] && l.available[k].contentURL || []).some((u) => typeof u === 'string' && u.endsWith(needle)));"
                      "  const had = findId(before);"
                      "  return applySelection({toImport: url}, Infinity).then(lists).then((l) => {"
                      "    const id = findId(l);"
                      "    if (!id) throw new Error('uBlock Origin turned the list down');"
                      "    const entry = l.available[id];"
                      "    const cache = l.cache && l.cache[id];"
                      "    return {id, custom: entry.group === 'custom', existed: !!had && before.available[had].off !== true,"
                      "      filters: entry.entryCount || 0, failed: !!(cache && cache.error !== undefined)};"
                      "  });"
                      "})";
  Call(kProfile, ScriptWith(script, @[ url ]), ^(id added, NSString *error) {
    if (!error && ![added isKindOfClass:NSDictionary.class]) error = @"no answer";
    if (!error) Publish(@{@"list" : added[@"id"], @"listEnabled" : @YES});
    ListsChanged(error, ^(NSString *changeError) { completion(changeError ? nil : added, changeError); });
  });
}

+ (void)removeList:(NSString *)listId completion:(void (^)(NSString *))completion {
  NSString *script = @"lists().then((l) => {"
                      "  const id = %@;"
                      "  if (!l.available[id] || l.available[id].group !== 'custom') throw new Error(`no added list ${id}`);"
                      "  return applySelection({toRemove: [id]});"
                      "})";
  Call(kProfile, ScriptWith(script, @[ listId ]), ^(id, NSString *error) {
    if (!error) Publish(@{@"list" : listId, @"listEnabled" : @NO});
    ListsChanged(error, completion);
  });
}

+ (void)isAllowedOnHost:(NSString *)host completion:(void (^)(BOOL))completion {
  NSString *script = @"trusted().then((t) => t.whitelist.some((d) => covers(d, %@)))";
  Call(kProfile, ScriptWith(script, @[ host.lowercaseString ]), ^(id allowed, NSString *error) {
    completion(!error && [allowed isKindOfClass:NSNumber.class] && [allowed boolValue]);
  });
}

+ (void)setAllowed:(BOOL)allowed onHost:(NSString *)host completion:(void (^)(NSString *))completion {
  NSString *script = @"trusted().then((t) => {"
                      "  const [allowed, host] = [%@, %@];"
                      "  const kept = t.whitelist.filter((d) => allowed ? d !== host : !covers(d, host));"
                      "  return send({what: 'setWhitelist', whitelist: (allowed ? kept.concat([host]) : kept).join('\\n')});"
                      "})";
  Call(kProfile, ScriptWith(script, @[ @(allowed), host.lowercaseString ]), ^(id, NSString *error) {
    if (!error) Publish(@{@"host" : host.lowercaseString, @"allowed" : @(allowed)});
    Changed(error, completion);
  });
}

+ (void)userFilters:(void (^)(NSDictionary<NSString *, id> *, NSString *))completion {
  NSString *script = @"send({what: 'readUserFilters'}).then((u) => ({content: typeof u.content === 'string' ? u.content : '', enabled: u.enabled !== false, trusted: !!u.trusted}))";
  Call(kProfile, script, ^(id value, NSString *error) {
    completion([value isKindOfClass:NSDictionary.class] ? value : nil, error ?: ([value isKindOfClass:NSDictionary.class] ? nil : @"no user filters"));
  });
}

+ (void)hiddenElementsInProfile:(NSString *)profile completion:(void (^)(NSArray<NSString *> *, NSString *))completion {
  Call(ardia_host::OriginalProfileName(profile), WithHidingRules(kReadHidden), ^(id filters, NSString *error) {
    completion(error ? nil : Strings(filters), error);
  });
}

+ (void)hideElements:(NSArray<NSString *> *)filters inProfile:(NSString *)profile completion:(void (^)(NSString *))completion {
  if (ardia_host::IsPrivateProfile(profile)) return completion(@"a private window keeps its hidden elements for the session");
  if (!filters.count) return completion(nil);
  Call(profile, WithHidingRules(ScriptWith(kHide, @[ filters ])), ^(id, NSString *error) {
    if (!error) Publish(@{@"userFilters" : @YES});
    completion(error);
  });
}

+ (void)restoreElements:(NSArray<NSString *> *)filters inProfile:(NSString *)profile completion:(void (^)(NSString *))completion {
  if (!filters.count) return completion(nil);
  Call(ardia_host::OriginalProfileName(profile), WithHidingRules(ScriptWith(kRestore, @[ filters ])), ^(id, NSString *error) {
    if (!error) Publish(@{@"userFilters" : @YES});
    completion(error);
  });
}

+ (void)devFailNextMessage {
  gFailNextMessage = true;
}

+ (void)devDelayNextLoad:(double)ms {
  gDelayNextLoadMs = ms;
}

@end
