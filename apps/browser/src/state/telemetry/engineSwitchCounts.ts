const none = () => ({
  switches: 0,
  switchesToWebKit: 0,
  switchesHidden: 0,
  switchMsTotal: 0,
  switchMsMax: 0,
  switchTimeouts: 0,
  scrollCarried: 0,
  zoomCarried: 0,
  cookiesToWebKit: 0,
  cookiesToChromium: 0,
  webKitExtensionsLoaded: 0,
  webKitExtensionsFailed: 0,
  webKitExtensionActions: 0,
  webKitAutofillFills: 0,
  webKitAutofillSaveOffers: 0,
  webKitAutofillSaves: 0,
  webKitNotifications: 0,
  webKitAutofillUpdateOffers: 0,
  webKitAutofillUpdates: 0,
  webKitAutofillNevers: 0,
  webKitCookiesReplaced: 0,
  webKitWorkerNotifications: 0,
  webKitWorkerShownNotifications: 0,
  webKitWorkerClicks: 0,
  webKitTranslations: 0,
  webKitShimDownloads: 0,
  webKitShimHistory: 0,
  webKitShimBookmarks: 0,
  webKitShimTabGroups: 0,
  webKitShimSidePanel: 0,
  webKitNativeHostLaunches: 0,
  webKitNativeHostFailures: 0,
  webKitPrivateExtensionsLoaded: 0,
  modeChanges: 0,
  modeChangesCancelled: 0,
  modeTabsMoved: 0,
});

let pending = none();

export type WebKitCount =
  | "autofillFill"
  | "autofillSaveOffer"
  | "autofillSave"
  | "notification"
  | "autofillUpdateOffer"
  | "autofillUpdate"
  | "autofillNever"
  | "cookieReplaced"
  | "workerNotification"
  | "workerShownNotification"
  | "workerClick"
  | "translation"
  | "extensionAction"
  | "shimDownloads"
  | "shimHistory"
  | "shimBookmarks"
  | "shimTabGroups"
  | "shimSidePanel"
  | "nativeHostLaunch"
  | "nativeHostFailure"
  | "privateExtensionLoaded";

const WEBKIT_COUNTS = {
  autofillFill: "webKitAutofillFills",
  autofillSaveOffer: "webKitAutofillSaveOffers",
  autofillSave: "webKitAutofillSaves",
  notification: "webKitNotifications",
  autofillUpdateOffer: "webKitAutofillUpdateOffers",
  autofillUpdate: "webKitAutofillUpdates",
  autofillNever: "webKitAutofillNevers",
  cookieReplaced: "webKitCookiesReplaced",
  workerNotification: "webKitWorkerNotifications",
  workerShownNotification: "webKitWorkerShownNotifications",
  workerClick: "webKitWorkerClicks",
  translation: "webKitTranslations",
  extensionAction: "webKitExtensionActions",
  shimDownloads: "webKitShimDownloads",
  shimHistory: "webKitShimHistory",
  shimBookmarks: "webKitShimBookmarks",
  shimTabGroups: "webKitShimTabGroups",
  shimSidePanel: "webKitShimSidePanel",
  nativeHostLaunch: "webKitNativeHostLaunches",
  nativeHostFailure: "webKitNativeHostFailures",
  privateExtensionLoaded: "webKitPrivateExtensionsLoaded",
} as const satisfies Record<WebKitCount, keyof ReturnType<typeof none>>;

export function noteEngineSwap(to: "chromium" | "webkit", swap: { ms: number; timedOut: boolean; hidden: boolean; scroll: boolean; zoom: boolean }) {
  pending.switches++;
  if (to === "webkit") pending.switchesToWebKit++;
  if (swap.hidden) pending.switchesHidden++;
  if (swap.timedOut) pending.switchTimeouts++;
  if (swap.scroll) pending.scrollCarried++;
  if (swap.zoom) pending.zoomCarried++;
  if (swap.hidden) return;
  const ms = Math.max(0, Math.round(swap.ms));
  pending.switchMsTotal += ms;
  pending.switchMsMax = Math.max(pending.switchMsMax, ms);
}

export function noteCookiesCarried(to: "chromium" | "webkit", count: number) {
  if (count > 0) pending[to === "webkit" ? "cookiesToWebKit" : "cookiesToChromium"] += count;
}

export function noteWebKitExtensions(loaded: number, failed: number) {
  pending.webKitExtensionsLoaded = Math.max(pending.webKitExtensionsLoaded, loaded);
  pending.webKitExtensionsFailed = Math.max(pending.webKitExtensionsFailed, failed);
}

export function noteEngineModeChange({ cancelled, moved }: { cancelled: boolean; moved: number }) {
  if (cancelled) return void pending.modeChangesCancelled++;
  pending.modeChanges++;
  pending.modeTabsMoved += Math.max(0, moved);
}

export function noteWebKitCount(name: WebKitCount) {
  const key = WEBKIT_COUNTS[name];
  if (key) pending[key]++;
}

export function takeEngineSwitchCounts() {
  const taken = pending;
  pending = none();
  return {
    engine_switches: taken.switches,
    engine_switches_to_webkit: taken.switchesToWebKit,
    engine_switches_hidden: taken.switchesHidden,
    engine_switch_ms_total: taken.switchMsTotal,
    engine_switch_ms_max: taken.switchMsMax,
    engine_switch_timeouts: taken.switchTimeouts,
    engine_switch_scroll_carried: taken.scrollCarried,
    engine_switch_zoom_carried: taken.zoomCarried,
    engine_switch_cookies_to_webkit: taken.cookiesToWebKit,
    engine_switch_cookies_to_chromium: taken.cookiesToChromium,
    webkit_extensions_loaded: taken.webKitExtensionsLoaded,
    webkit_extensions_failed: taken.webKitExtensionsFailed,
    webkit_extension_actions: taken.webKitExtensionActions,
    webkit_autofill_fills: taken.webKitAutofillFills,
    webkit_autofill_save_offers: taken.webKitAutofillSaveOffers,
    webkit_autofill_saves: taken.webKitAutofillSaves,
    webkit_notifications: taken.webKitNotifications,
    webkit_autofill_update_offers: taken.webKitAutofillUpdateOffers,
    webkit_autofill_updates: taken.webKitAutofillUpdates,
    webkit_autofill_nevers: taken.webKitAutofillNevers,
    webkit_cookies_replaced: taken.webKitCookiesReplaced,
    webkit_worker_notifications: taken.webKitWorkerNotifications,
    webkit_worker_shown_notifications: taken.webKitWorkerShownNotifications,
    webkit_worker_clicks: taken.webKitWorkerClicks,
    webkit_translations: taken.webKitTranslations,
    webkit_extension_downloads_calls: taken.webKitShimDownloads,
    webkit_extension_history_calls: taken.webKitShimHistory,
    webkit_extension_bookmarks_calls: taken.webKitShimBookmarks,
    webkit_extension_tab_groups_calls: taken.webKitShimTabGroups,
    webkit_extension_side_panel_calls: taken.webKitShimSidePanel,
    webkit_native_host_launches: taken.webKitNativeHostLaunches,
    webkit_native_host_failures: taken.webKitNativeHostFailures,
    webkit_private_extensions_loaded: taken.webKitPrivateExtensionsLoaded,
    engine_mode_changes: taken.modeChanges,
    engine_mode_changes_cancelled: taken.modeChangesCancelled,
    engine_mode_tabs_moved: taken.modeTabsMoved,
  };
}
