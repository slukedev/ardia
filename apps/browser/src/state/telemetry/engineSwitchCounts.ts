import { isWebKitAutofillCount, noteWebKitAutofillCount, takeWebKitAutofillCounts, type WebKitAutofillCount } from "./webKitAutofillCounts";
import { isWebKitContentBlockerCount, noteWebKitContentBlockerCount, takeWebKitContentBlockerCounts, type WebKitContentBlockerCount } from "./webKitContentBlockerCounts";
import { onWebKitCount } from "../../platform/webkit";
import { counted, onConsentPeriodChange, type ConsentToken } from "./choice";
import { nativeConsent } from "./nativeConsent";
import { fieldName } from "./consentPeriod";
import { WEBKIT_COUNTS, type WebKitCount } from "./webKitPageCountNames";

const none = () => ({
  switches: 0,
  switchesToWebKit: 0,
  switchesHidden: 0,
  switchMsTotal: 0,
  switchMsMax: 0,
  switchTimeouts: 0,
  scrollCarried: 0,
  zoomCarried: 0,
  webKitAutofillFills: 0,
  webKitAutofillSaveOffers: 0,
  webKitAutofillSaves: 0,
  webKitNotifications: 0,
  webKitAutofillUpdateOffers: 0,
  webKitAutofillUpdates: 0,
  webKitAutofillNevers: 0,
  webKitPasswordsLeftToManager: 0,
  webKitWorkerNotifications: 0,
  webKitWorkerShownNotifications: 0,
  webKitWorkerClicks: 0,
  webKitTranslations: 0,
  webKitSiteSettingsApplied: 0,
  webKitUploadsFiltered: 0,
  webKitScreenShareRequests: 0,
  webKitScreenShareAllowed: 0,
  webKitDevToolsOpened: 0,
  webKitViewSources: 0,
  webKitPagesSaved: 0,
  webKitSavePageFailures: 0,
  webKitQuarantineFailures: 0,
  webKitContextMenus: 0,
  webKitLinkPeeks: 0,
  webKitLinkSplits: 0,
  webKitLittleArdiaLinks: 0,
  webKitScrollZooms: 0,
  webKitSampledTints: 0,
  webKitAuthPrompts: 0,
  webKitAuthPromptsBlocked: 0,
  webKitDialogsSuppressedWhileHidden: 0,
  webKitScriptDialogsSuppressed: 0,
  webKitDialogsHeldWhileHidden: 0,
  webKitCertificateInterstitials: 0,
  webKitCertificateProceeds: 0,
  webKitPopupsBlocked: 0,
  webKitBlockedPopupsOpened: 0,
  webKitErrorPageRetries: 0,
  webKitNativeFinds: 0,
  webKitFallbackFinds: 0,
  webKitSelectionPopovers: 0,
  webKitAppBadges: 0,
  webKitFaviconChanges: 0,
  webKitLinkDrops: 0,
  webKitPageMutes: 0,
  webKitSoundRuleMutes: 0,
  webKitWebAudioAudible: 0,
  webKitPageMuteFallbacks: 0,
  webKitFullscreens: 0,
  webKitDiscards: 0,
  webKitDiscardWakes: 0,
  webKitHistoryRestores: 0,
  webKitUnresponsive: 0,
  webKitUnresponsiveEnded: 0,
  webKitDownloadsSkipped: 0,
  modeChanges: 0,
  modeChangesCancelled: 0,
  modeTabsMoved: 0,
  modeVideoNotices: 0,
  modeVideoNoticeOpens: 0,
});

let tally = none();

onConsentPeriodChange(() => (tally = none()));

const webKitCountKeys: Record<WebKitCount, keyof ReturnType<typeof none>> = WEBKIT_COUNTS;

type EngineSwap = { ms: number; timedOut: boolean; hidden: boolean; scroll: boolean; zoom: boolean };

export function noteEngineSwap(to: "chromium" | "webkit", swap: EngineSwap, consent: ConsentToken | null) {
  counted(consent, () => addSwap(to, swap));
}

function addSwap(to: "chromium" | "webkit", swap: EngineSwap) {
  tally.switches++;
  if (to === "webkit") tally.switchesToWebKit++;
  if (swap.hidden) tally.switchesHidden++;
  if (swap.timedOut) tally.switchTimeouts++;
  if (swap.scroll) tally.scrollCarried++;
  if (swap.zoom) tally.zoomCarried++;
  if (swap.hidden) return;
  const ms = Math.max(0, Math.round(swap.ms));
  tally.switchMsTotal += ms;
  tally.switchMsMax = Math.max(tally.switchMsMax, ms);
}

export function noteEngineModeChange({ cancelled, moved }: { cancelled: boolean; moved: number }, consent: ConsentToken | null) {
  counted(consent, () => {
    if (cancelled) return void tally.modeChangesCancelled++;
    tally.modeChanges++;
    tally.modeTabsMoved += Math.max(0, moved);
  });
}

export function noteEngineModeVideoNotice(event: "shown" | "opened", consent: ConsentToken | null) {
  counted(consent, () => void tally[event === "shown" ? "modeVideoNotices" : "modeVideoNoticeOpens"]++);
}

export function noteWebKitCount(name: WebKitCount | WebKitAutofillCount | WebKitContentBlockerCount, consent: ConsentToken | null) {
  if (isWebKitContentBlockerCount(name)) return noteWebKitContentBlockerCount(name, consent);
  if (isWebKitAutofillCount(name)) return noteWebKitAutofillCount(name, consent);
  const key = webKitCountKeys[name];
  if (key) counted(consent, () => void tally[key]++);
}

let countsListening = false;

export function startWebKitCounts() {
  if (countsListening) return;
  countsListening = true;
  onWebKitCount((count) => noteWebKitCount(count.name, nativeConsent(count)));
}

export function takeEngineSwitchCounts() {
  const taken = tally;
  tally = none();
  return {
    ...takeWebKitAutofillCounts(),
    ...takeWebKitContentBlockerCounts(),
    engine_switches: taken.switches,
    engine_switches_to_webkit: taken.switchesToWebKit,
    engine_switches_hidden: taken.switchesHidden,
    engine_switch_ms_total: taken.switchMsTotal,
    engine_switch_ms_max: taken.switchMsMax,
    engine_switch_timeouts: taken.switchTimeouts,
    engine_switch_scroll_carried: taken.scrollCarried,
    engine_switch_zoom_carried: taken.zoomCarried,
    webkit_autofill_fills: taken.webKitAutofillFills,
    webkit_autofill_save_offers: taken.webKitAutofillSaveOffers,
    webkit_autofill_saves: taken.webKitAutofillSaves,
    webkit_notifications: taken.webKitNotifications,
    webkit_autofill_update_offers: taken.webKitAutofillUpdateOffers,
    webkit_autofill_updates: taken.webKitAutofillUpdates,
    webkit_autofill_nevers: taken.webKitAutofillNevers,
    webkit_passwords_left_to_manager: taken.webKitPasswordsLeftToManager,
    webkit_worker_notifications: taken.webKitWorkerNotifications,
    webkit_worker_shown_notifications: taken.webKitWorkerShownNotifications,
    webkit_worker_clicks: taken.webKitWorkerClicks,
    webkit_translations: taken.webKitTranslations,
    webkit_site_settings_applied: taken.webKitSiteSettingsApplied,
    webkit_uploads_filtered: taken.webKitUploadsFiltered,
    webkit_screen_share_requests: taken.webKitScreenShareRequests,
    webkit_screen_share_allowed: taken.webKitScreenShareAllowed,
    webkit_devtools_opened: taken.webKitDevToolsOpened,
    webkit_view_sources: taken.webKitViewSources,
    webkit_pages_saved: taken.webKitPagesSaved,
    webkit_save_page_failures: taken.webKitSavePageFailures,
    webkit_quarantine_failures: taken.webKitQuarantineFailures,
    webkit_context_menus: taken.webKitContextMenus,
    webkit_link_peeks: taken.webKitLinkPeeks,
    webkit_link_splits: taken.webKitLinkSplits,
    webkit_little_ardia_links: taken.webKitLittleArdiaLinks,
    webkit_scroll_zooms: taken.webKitScrollZooms,
    webkit_sampled_tints: taken.webKitSampledTints,
    webkit_auth_prompts: taken.webKitAuthPrompts,
    webkit_auth_prompts_blocked: taken.webKitAuthPromptsBlocked,
    webkit_dialogs_suppressed_while_hidden: taken.webKitDialogsSuppressedWhileHidden,
    webkit_script_dialogs_suppressed: taken.webKitScriptDialogsSuppressed,
    webkit_dialogs_held_while_hidden: taken.webKitDialogsHeldWhileHidden,
    webkit_certificate_interstitials: taken.webKitCertificateInterstitials,
    webkit_certificate_proceeds: taken.webKitCertificateProceeds,
    webkit_popups_blocked: taken.webKitPopupsBlocked,
    webkit_blocked_popups_opened: taken.webKitBlockedPopupsOpened,
    [fieldName("webKitErrorPageRetries")]: taken.webKitErrorPageRetries,
    webkit_native_finds: taken.webKitNativeFinds,
    webkit_fallback_finds: taken.webKitFallbackFinds,
    webkit_selection_popovers: taken.webKitSelectionPopovers,
    webkit_app_badges: taken.webKitAppBadges,
    webkit_favicon_changes: taken.webKitFaviconChanges,
    webkit_link_drops: taken.webKitLinkDrops,
    webkit_page_mutes: taken.webKitPageMutes,
    webkit_sound_rule_mutes: taken.webKitSoundRuleMutes,
    webkit_web_audio_audible: taken.webKitWebAudioAudible,
    webkit_page_mute_fallbacks: taken.webKitPageMuteFallbacks,
    webkit_fullscreens: taken.webKitFullscreens,
    webkit_discards: taken.webKitDiscards,
    webkit_discard_wakes: taken.webKitDiscardWakes,
    webkit_history_restores: taken.webKitHistoryRestores,
    webkit_unresponsive: taken.webKitUnresponsive,
    webkit_unresponsive_ended: taken.webKitUnresponsiveEnded,
    webkit_downloads_skipped: taken.webKitDownloadsSkipped,
    engine_mode_changes: taken.modeChanges,
    engine_mode_changes_cancelled: taken.modeChangesCancelled,
    engine_mode_tabs_moved: taken.modeTabsMoved,
    engine_mode_video_notices: taken.modeVideoNotices,
    engine_mode_video_notice_opens: taken.modeVideoNoticeOpens,
  };
}
