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
});

let pending = none();

export type WebKitCount = "autofillFill" | "autofillSaveOffer" | "autofillSave" | "notification" | "extensionAction";

const WEBKIT_COUNTS = {
  autofillFill: "webKitAutofillFills",
  autofillSaveOffer: "webKitAutofillSaveOffers",
  autofillSave: "webKitAutofillSaves",
  notification: "webKitNotifications",
  extensionAction: "webKitExtensionActions",
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

export const noteWebKitCount = (name: WebKitCount) => void pending[WEBKIT_COUNTS[name]]++;

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
  };
}
