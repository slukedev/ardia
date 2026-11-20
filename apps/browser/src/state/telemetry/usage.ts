import { listTasks, type EngineTask } from "../../platform/performance";
import { currentAppIcon, listComponents, onAppEvent } from "../../platform/app";
import { useTranslate } from "../site/translate";
import { useBrowser } from "../browser/store";
import { keysOf } from "../browser/changes";
import { takeOpenTabSyncCounts, takeSnapshotWrites, useSync } from "../sync/engine";
import { takeSyncCodeCounts } from "../sync/recoveryKit";
import { capture, consentNow, consentToken, counted, consentOrNow, countFor, endSession, fieldsOf, flush, isSharing, markSettingsSnapshot, settingsSnapshotDay, startClient, stillValid, watchConsentBoundary, withHourlyExtras, type ConsentToken } from "./usageClient";
import { reportLocalStore, startLocalStore } from "./localStoreReport";
import { watchExtensionInstalls } from "./extensionInstalls";
import { nativeConsent } from "./nativeConsent";
import { startWatchChecks } from "./watch";
import { appIconSetting, currentThemeFileSnapshot, customColorProfiles, narrowWindows, openTabSyncProfiles, SETTINGS_SNAPSHOT_EVENT, settingsSnapshot, widevineSetting } from "./settingsSnapshot";
import { utcDay } from "./daily";
import { percentile } from "./transport";
import { reportNativeCrashes } from "./errors";
import { emitJourneys, journeysEnding, startJourneys } from "./journeys";
import { commandBarPlacementLabel, takeExternalAppRequests, takeNotificationRequestCounts, takeRecentlyClosedCounts, takeHistoryRemovalCounts, takeOmniboxLatency, takePopupTabCounts, takeSearchSuggests } from "./track";
import { contextSamples, noteAppMemory, recordContext, takeMainProcessWork, takeContentDriftCounts, takeColdTabHoldCounts, startContextSamples, stopContextSamples, watchEngineReports } from "./diagnostics";
import { emitTabPresses } from "./tabPresses";
import { takeFreezeCounts } from "./freezes";
import { switcherSwitchProperties } from "./switcherPresses";
import { profileSwitched } from "./profileSwap";
import type { SavedContext } from "./savedContext";
import { splitTabIds } from "../splits/splits";
import { windowsRealignedToAutoHideTabsAtLaunch } from "../session/persist";
import { takeAutoHideTabsChoices, takeTornOffWindowsKeptAutoHide } from "./autoHideTabsChoices";
import { takeTabSwitcherMenuReleases, takeTabSwitcherOpensInWebKit, takeTabSwitcherRowCloses, takeTabSwitcherScrollCounts } from "./tabSwitcherOpens";
import { takeTabSleepCounts } from "./tabSleepCounts";
import { noteAutoPictureInPictureNothingPlaying, takePictureInPictureCounts } from "./pictureInPictureCounts";
import { takeStripBounceCounts } from "../tabs/stripBounce";
import { useToolbarAutoHide } from "../windows/toolbarAutoHide";
import { toolbarBounces } from "./toolbarBounces";
import { takeStuckDragCounts } from "./stuckDrags";
import { takeUrlCopyCounts } from "./urlCopies";
import { takeThemePresetCounts } from "./themePresetCounts";
import { takeConfigProblemToastCounts } from "./configProblemToasts";
import { takeWebKitMediaFaultCounts } from "./webkitMediaFaults";
import { takeStripHoverCardCounts } from "./stripHoverCards";
import { takeLittleArdiaEscapeCloses } from "./littleArdiaEscapes";
import { takeLiveCompletedTabsClosed } from "./liveCompletedTabs";
import { takeLiveHideCounts } from "./liveHides";
import { takeTidyTabsCounts } from "./tidyTabsCounts";
import { takeProtectedVideoCounts } from "./protectedVideoCounts";
import { takeEngineSwitchCounts } from "./engineSwitchCounts";
import { takeMediaCardCounts } from "./mediaCardCounts";
import { takeBookmarkMoveCounts } from "./bookmarkMoves";
import { takeDownloadsPanelCounts } from "./downloadsPanelCounts";
import { takeDownloadWork } from "./downloadWork";
import { airTrafficSnapshot, takeAirTrafficCounts } from "./airTrafficCounts";
import { takeDockCounts } from "./dockCounts";
import { takeCliCounts } from "./cliCounts";
import { pluginsSnapshot, takePluginCounts } from "./pluginCounts";
import { passwordManagerSnapshot } from "../site/passwordManager";
import { keptTabsAdded } from "./keptTabs";
import { takeTabStripCounts } from "./tabStripCounts";
import { takeFocusFeatureCounts } from "./focusFeatureCounts";
import { takeWindowPlacementCounts } from "./windowPlacementCounts";
import { takeSidebarResizeCounts } from "./sidebarResizeCounts";
import { takeBookmarkletCounts } from "./bookmarkletCounts";
import { takeWorkCounts } from "./workCounts";
import { launchEvents } from "./launchEvents";
import { releaseTopAppsSharing } from "./topAppsSharing";
import { watchPopupProtectedMedia } from "./popupProtectedMedia";

const HOUR_MS = 60 * 60_000;
const FIRST_MEMORY_SAMPLE_MS = 10 * 60_000, FIRST_SETTINGS_SNAPSHOT_MS = 2 * 60_000;
const LOCAL_STORE_LAUNCH_DELAY_MS = 20_000;
const startedAt = Date.now();
const NO_COUNTS = { tabs: 0, windows: 0, fullScreens: 0, sidebarPeeks: 0, sidebarPeekBounces: 0, sidebarPeekPageHides: 0, sidebarEmptyWindowPeeks: 0, sidebarPeekCardMoves: 0, cliTabEdits: 0, cliGroupEdits: 0, cliEditFailures: 0, popoverPressCloses: 0, popoverEscapeCloses: 0, siteAutoplayBlocks: 0, siteAutoplayAllows: 0, autoplayPlaysBlocked: 0, siteSettingsOpens: 0, sidebarFieldSiteControlsOpens: 0, siteManageExtensionsOpens: 0, tabSwitcherOpens: 0, tabSwitcherClosedLeftOut: 0, tabSwitcherUnseenLast: 0, approvalNoticesDeferred: 0, reopenedPages: 0, reopenedPagesWithBack: 0, backClosesToOpener: 0, groupTabsKept: 0, groupHeaderHides: 0, peekPinchOpens: 0, peekPinchCloses: 0, peeksShownAgain: 0, littleArdiaPinchOpens: 0, littleArdiaPinchCloses: 0, littleArdiaSwipeCloses: 0, littleArdiaSwipeCloseCancels: 0, externalLinksTabSettingOff: 0, externalLinksTabSettingOn: 0, externalLinksLittleSettingOn: 0, externalLinksLittleSettingOff: 0, autoHideTabsToggles: 0, windowsRealignedToAutoHideTabs: 0, tabStripPeeks: 0, tabStripMenuOpens: 0, tabStripOverflowOpens: 0, tabPeeksWithAutoHideOff: 0, toolbarScrollHides: 0, toolbarScrollHideBounces: 0, toolbarPeeks: 0, toolbarPeekPageHides: 0, toolbarMotionPageHides: 0, cardResizeLayouts: 0, cardResizeLayoutsApplied: 0, importedPinnedRows: 0, importedSplits: 0, importedSpaces: 0, importedContainerSpaces: 0, importedDataProfiles: 0, importedEssentials: 0, importedStartersNamed: 0, splitPaneCloses: 0, splitViewCloses: 0, splitDividerResets: 0, windowCloseTabsKept: 0, sharesPickedTab: 0, sharesPickedWindow: 0, sharesPickedScreen: 0, sharesWithCaptureController: 0, screenRecordingMissing: 0, screenRecordingAsked: 0, extensionInstallPrompts: 0, extensionInstallPromptsStale: 0, extensionProfilePageOpens: 0, extensionProfilePageReroutes: 0, privateWindowExtensionOpens: 0, sidePanelsKeptOnSwitch: 0, emptyTabSidebarExtensionPresses: 0, toolbarExtensionMoves: 0, toolbarExtensionMenuMoves: 0, toolbarAnchorMoves: 0, toolbarAnchorMisses: 0, contentBlockerUnavailable: 0, contentBlockerPagesBehind: 0, contentBlockerWriteFailures: 0, contentBlockerCustomListsAdded: 0, contentBlockerCustomListAddFailures: 0, contentBlockerCustomListsRemoved: 0, newTabNoticesShown: 0, newTabNoticePresses: 0, statusBubbleTopShows: 0, loadingFieldShows: 0, loadingPillShows: 0, loadingPillLongShows: 0, loadingPillSkips: 0, dockReopens: 0, dockReopensPastFloating: 0, pipActivationReturns: 0, pipActivationReturnFailures: 0, sidebarMotionMerges: 0, sidebarSlideOverruns: 0, webKitPagesKeptHidden: 0, newTabBarKeeps: 0, newTabBarLaunchShows: 0, newTabLingers: 0, newTabLingersLate: 0, newTabLeavesForWebKit: 0, newTabLeavesWithoutLinger: 0, barSplitOpens: 0, barSplitFullTabs: 0, splitSuggestionKeyPicks: 0, settingsSearchKeyboardReveals: 0, settingsSearchClickReveals: 0, settingsSearches: 0, settingsSearchesEmpty: 0, settingsSearchesDropped: 0, settingsSearchTopPicks: 0, settingsSearchTop3Picks: 0, settingsSearchLowerPicks: 0, settingsSearchUnshownReveals: 0, shortcutsKeySearchesTyped: 0, shortcutsKeySearchesRecorded: 0, shortcutsKeySearchesEmpty: 0, settingsSearchKeySearches: 0, settingsSearchKeyHitOpens: 0, autoPictureInPictureKept: 0, autoPictureInPictureStayedOnAppSwitch: 0, selectionCloseKeys: 0, selectionCloseKeyTabs: 0, onboardingImports: 0, onboardingHeliumImports: 0, onboardingListedOnlyImports: 0, onboardingGlassPicks: 0, onboardingClassicPicks: 0, onboardingTintedGlassPicks: 0, onboardingStepsCompleted: 0, onboardingStepsSkipped: 0, onboardingRedoOpened: 0, onboardingRedoCompleted: 0, onboardingRedoCancelled: 0, onboardingPresetKeptImports: 0, updateChannelSwitches: 0, updateChannelSwitchOffers: 0, updateChannelSwitchUpToDate: 0, updateChannelSwitchCheckFailures: 0, cleanUpSuggestionShows: 0, cleanUpSuggestionOnce: 0, cleanUpSuggestionDaily: 0, cleanUpSuggestionNotNow: 0, cleanUpSuggestionNeverAgain: 0, cleanUpUndos: 0, linkTabsMatched: 0, linkTabWaitsSkipped: 0, linkTabWaitTimeouts: 0, historySearchFocusRequests: 0, historySearchFocused: 0 , selectedRowPillShows: 0, selectedRowPillPresses: 0, webKitLimitsFromEngineRow: 0, webKitLimitsFromEnginesPane: 0 };
let counts = { ...NO_COUNTS }, countsSince = Date.now();
const RENAMED: Partial<Record<keyof typeof NO_COUNTS, string>> = { siteSettingsOpens: "site_settings_opens_from_site_controls", siteManageExtensionsOpens: "extensions_manage_opens_from_site_controls", sidebarFieldSiteControlsOpens: "site_controls_opens_from_sidebar_field" };
const bump = (consent: ConsentToken | null | undefined, add: Partial<Record<keyof typeof NO_COUNTS, number>>) => countFor(consentOrNow(consent), () => { for (const key in add) counts[key as keyof typeof NO_COUNTS] += add[key as keyof typeof NO_COUNTS] ?? 0; });

function emitCounts(consent: ConsentToken | null) {
  const snapshots = takeSnapshotWrites(), tornOffKept = takeTornOffWindowsKeptAutoHide(), switcherOpensInWebKit = takeTabSwitcherOpensInWebKit(), switcherRowCloses = takeTabSwitcherRowCloses(), switcherScrolls = takeTabSwitcherScrollCounts(), switcherMenuReleases = takeTabSwitcherMenuReleases(), stuckDrags = takeStuckDragCounts(), urlCopies = takeUrlCopyCounts(), themePresets = takeThemePresetCounts(), configProblemToasts = takeConfigProblemToastCounts(), stripHoverCards = takeStripHoverCardCounts(), externalAppRequests = takeExternalAppRequests(), tabSleeps = takeTabSleepCounts(), syncCodes = takeSyncCodeCounts(), openTabSync = takeOpenTabSyncCounts(), escapeCloses = takeLittleArdiaEscapeCloses(), liveCompletedTabsClosed = takeLiveCompletedTabsClosed(), liveHides = takeLiveHideCounts(), tidyTabs = takeTidyTabsCounts(), mediaCard = takeMediaCardCounts(), bookmarkMoves = takeBookmarkMoveCounts(), downloadsPanel = takeDownloadsPanelCounts(), downloadWork = takeDownloadWork(), webKitFaults = takeWebKitMediaFaultCounts(), airTraffic = takeAirTrafficCounts(), cliCounts = takeCliCounts(), pluginCounts = takePluginCounts(), dock = takeDockCounts(), tabStrip = takeTabStripCounts(), sidebarResizes = takeSidebarResizeCounts(), bookmarklets = takeBookmarkletCounts(), windowPlacement = takeWindowPlacementCounts(), notificationRequests = takeNotificationRequestCounts(), recentlyClosed = takeRecentlyClosedCounts(), historyRemovals = takeHistoryRemovalCounts(), popupTabs = takePopupTabCounts(), focusFeatures = takeFocusFeatureCounts(), protectedVideo = takeProtectedVideoCounts(), engineSwitch = takeEngineSwitchCounts(), work = takeWorkCounts();
  const { nothingPlaying: autoPictureInPictureNothingPlaying, backToTab, backToTabFromOtherApp, drags: pipDrags, resizes: pipResizes, clickSkips, handleUnstashes: pipHandleUnstashes, standIns: pipStandIns } = takePictureInPictureCounts();
  const stripBounces = takeStripBounceCounts();
  counts.autoHideTabsToggles += takeAutoHideTabsChoices();
  if ((Object.values(work).some(Boolean) || Object.values(counts).some(Boolean) || Object.values(dock).some(Boolean) || tornOffKept > 0 || Object.values(tabSleeps).some(Boolean) || Object.values(themePresets).some(Boolean) || Object.values(syncCodes).some(Boolean) || Object.values(openTabSync).some(Boolean) || Object.values(stuckDrags).some(Boolean) || Object.values(escapeCloses).some(Boolean) || Object.values(liveHides).some(Boolean) || Object.values(tidyTabs).some(Boolean) || Object.values(mediaCard).some(Boolean) || bookmarkMoves.bookmark_moves || Object.values(downloadsPanel).some(Boolean) || Object.values(downloadWork).some(Boolean) || Object.values(tabStrip).some(Boolean) || Object.values(sidebarResizes).some(Boolean) || Object.values(bookmarklets).some(Boolean) || Object.keys(webKitFaults).length || Object.values(airTraffic).some(Boolean) || Object.values(cliCounts).some(Boolean) || Object.values(pluginCounts).some(Boolean) || Object.values(externalAppRequests).some(Boolean) || urlCopies.url_copies || configProblemToasts.config_problem_toasts || configProblemToasts.config_problem_toast_dismissals || stripHoverCards.tab_strip_hover_cards || liveCompletedTabsClosed || snapshots.count || snapshots.cycles || snapshots.removedProfiles || snapshots.removedDevices || snapshots.removalsReturned || switcherOpensInWebKit || switcherRowCloses || Object.values(switcherScrolls).some(Boolean) || switcherMenuReleases || autoPictureInPictureNothingPlaying || backToTab.chromium || backToTab.webkit || Object.values(stripBounces).some(Boolean) || pipDrags.moved || pipResizes.started || clickSkips.back || clickSkips.ahead || pipHandleUnstashes || pipStandIns.pinches || pipStandIns.timeouts || Object.values(windowPlacement).some(Boolean) || Object.values(popupTabs).some(Boolean) || Object.values(notificationRequests).some(Boolean) || recentlyClosed.recently_closed_clears || Object.values(historyRemovals).some(Boolean) || Object.values(historyRemovals).some(Boolean) || Object.values(focusFeatures).some(Boolean) || Object.values(protectedVideo).some(Boolean) || Object.values(engineSwitch).some(Boolean))) {
    capture("usage_counts", {
      ...work, tabs_opened: counts.tabs, windows_opened: counts.windows,
      full_screens_entered: counts.fullScreens,
      sidebar_peeks: counts.sidebarPeeks, sidebar_empty_window_peeks: counts.sidebarEmptyWindowPeeks, sidebar_peek_card_moves: counts.sidebarPeekCardMoves,
      sidebar_peek_bounces: counts.sidebarPeekBounces,
      sidebar_peek_page_hides: counts.sidebarPeekPageHides, ...dock,
      cli_tab_edits: counts.cliTabEdits, cli_group_edits: counts.cliGroupEdits, cli_edit_failures: counts.cliEditFailures, ...cliCounts, ...pluginCounts,
      ...focusFeatures, ...sidebarResizes, ...bookmarklets, ...windowPlacement, ...stuckDrags, ...urlCopies, ...themePresets, ...configProblemToasts, ...stripHoverCards, ...externalAppRequests, ...webKitFaults, ...tabSleeps, ...syncCodes, ...openTabSync, ...liveHides, ...tidyTabs, ...mediaCard, ...bookmarkMoves, ...downloadsPanel, ...downloadWork, ...airTraffic, ...tabStrip, ...notificationRequests, ...recentlyClosed, ...historyRemovals, ...protectedVideo, ...engineSwitch, ...popupTabs, live_completed_tabs_closed: liveCompletedTabsClosed,
      popover_press_closes: counts.popoverPressCloses, popover_escape_closes: counts.popoverEscapeCloses, site_autoplay_blocks: counts.siteAutoplayBlocks, site_autoplay_allows: counts.siteAutoplayAllows, autoplay_plays_blocked: counts.autoplayPlaysBlocked, site_settings_opens_from_site_controls: counts.siteSettingsOpens, site_controls_opens_from_sidebar_field: counts.sidebarFieldSiteControlsOpens, extensions_manage_opens_from_site_controls: counts.siteManageExtensionsOpens,
      tab_switcher_opens: counts.tabSwitcherOpens,
      tab_switcher_opens_in_webkit: switcherOpensInWebKit, tab_switcher_row_closes: switcherRowCloses, ...switcherScrolls, tab_switcher_menu_releases: switcherMenuReleases,
      tab_switcher_closed_left_out: counts.tabSwitcherClosedLeftOut,
      tab_switcher_unseen_last: counts.tabSwitcherUnseenLast,
      approval_notices_deferred: counts.approvalNoticesDeferred,
      reopened_pages: counts.reopenedPages,
      reopened_pages_with_back: counts.reopenedPagesWithBack, back_closes_to_opener: counts.backClosesToOpener,
      group_tabs_kept: counts.groupTabsKept,
      group_header_hides: counts.groupHeaderHides,
      sidebar_motion_merges: counts.sidebarMotionMerges, sidebar_slide_overruns: counts.sidebarSlideOverruns,
      peek_pinch_opens: counts.peekPinchOpens, peek_pinch_closes: counts.peekPinchCloses, peeks_shown_again: counts.peeksShownAgain,
      little_ardia_pinch_opens: counts.littleArdiaPinchOpens, little_ardia_pinch_closes: counts.littleArdiaPinchCloses, ...escapeCloses, little_ardia_swipe_closes: counts.littleArdiaSwipeCloses, little_ardia_swipe_close_cancels: counts.littleArdiaSwipeCloseCancels, external_links_tab_setting_off: counts.externalLinksTabSettingOff, external_links_tab_setting_on: counts.externalLinksTabSettingOn, external_links_little_setting_on: counts.externalLinksLittleSettingOn, external_links_little_setting_off: counts.externalLinksLittleSettingOff,
      auto_hide_tabs_toggles: counts.autoHideTabsToggles,
      windows_realigned_to_auto_hide_tabs: counts.windowsRealignedToAutoHideTabs, torn_off_windows_kept_auto_hide: tornOffKept,
      tab_strip_peeks: counts.tabStripPeeks, tab_strip_menu_opens: counts.tabStripMenuOpens, tab_strip_overflow_opens: counts.tabStripOverflowOpens, tab_peeks_with_auto_hide_off: counts.tabPeeksWithAutoHideOff,
      imported_pinned_rows: counts.importedPinnedRows,
      imported_splits: counts.importedSplits, imported_spaces: counts.importedSpaces, imported_container_spaces: counts.importedContainerSpaces, imported_data_profiles: counts.importedDataProfiles, imported_essentials: counts.importedEssentials, imported_starters_named: counts.importedStartersNamed,
      split_pane_closes: counts.splitPaneCloses, split_divider_resets: counts.splitDividerResets,
      split_view_closes: counts.splitViewCloses,
      window_close_tabs_kept: counts.windowCloseTabsKept,
      sync_snapshots_written: snapshots.count, synced_profiles_removed: snapshots.removedProfiles, synced_devices_removed: snapshots.removedDevices, synced_removals_returned: snapshots.removalsReturned, sync_cycles: snapshots.cycles, sync_cycle_ms: snapshots.ms, sync_cycle_longest_ms: snapshots.longestMs,
      sync_snapshot_kb_written: Math.round(snapshots.bytes / 1024), auto_pip_nothing_playing: autoPictureInPictureNothingPlaying, pip_back_to_tab: backToTab.chromium, pip_back_to_tab_webkit: backToTab.webkit, pip_back_to_tab_from_other_app: backToTabFromOtherApp, ...stripBounces, pip_drags: pipDrags.moved, pip_drags_off_cursor: pipDrags.offCursor, pip_drags_slow_move: pipDrags.slowMove, pip_resizes: pipResizes.started, pip_resizes_without_cursor: pipResizes.withoutCursor, pip_click_skips_back: clickSkips.back, pip_click_skips_ahead: clickSkips.ahead, pip_handle_unstashes: pipHandleUnstashes, pip_pinches: pipStandIns.pinches, pip_stand_in_timeouts: pipStandIns.timeouts,
      toolbar_scroll_hides: counts.toolbarScrollHides,
      toolbar_scroll_hide_bounces: counts.toolbarScrollHideBounces, toolbar_peeks: counts.toolbarPeeks, toolbar_peek_page_hides: counts.toolbarPeekPageHides, toolbar_motion_page_hides: counts.toolbarMotionPageHides,
      card_resize_layouts: counts.cardResizeLayouts,
      card_resize_layouts_applied: counts.cardResizeLayoutsApplied,
      shares_picked_tab: counts.sharesPickedTab,
      shares_picked_window: counts.sharesPickedWindow,
      shares_picked_screen: counts.sharesPickedScreen,
      shares_with_capture_controller: counts.sharesWithCaptureController,
      share_picker_screen_recording_missing: counts.screenRecordingMissing,
      share_picker_screen_recording_asked: counts.screenRecordingAsked,
      extension_install_prompts: counts.extensionInstallPrompts, extension_install_prompts_stale: counts.extensionInstallPromptsStale, extension_profile_page_opens: counts.extensionProfilePageOpens, extension_profile_page_reroutes: counts.extensionProfilePageReroutes,
      private_window_extension_opens: counts.privateWindowExtensionOpens, side_panels_kept_on_switch: counts.sidePanelsKeptOnSwitch,
      empty_tab_sidebar_extension_presses: counts.emptyTabSidebarExtensionPresses, toolbar_extension_moves: counts.toolbarExtensionMoves, toolbar_extension_menu_moves: counts.toolbarExtensionMenuMoves, toolbar_anchor_moves: counts.toolbarAnchorMoves, toolbar_anchor_misses: counts.toolbarAnchorMisses,
      content_blocker_unavailable: counts.contentBlockerUnavailable, content_blocker_pages_behind: counts.contentBlockerPagesBehind, content_blocker_write_failures: counts.contentBlockerWriteFailures, content_blocker_custom_lists_added: counts.contentBlockerCustomListsAdded, content_blocker_custom_list_add_failures: counts.contentBlockerCustomListAddFailures, content_blocker_custom_lists_removed: counts.contentBlockerCustomListsRemoved,
      new_tab_notices_shown: counts.newTabNoticesShown,
      new_tab_notice_presses: counts.newTabNoticePresses, selected_row_pill_shows: counts.selectedRowPillShows, selected_row_pill_presses: counts.selectedRowPillPresses,
      status_bubble_top_shows: counts.statusBubbleTopShows, loading_field_shows: counts.loadingFieldShows, loading_pill_shows: counts.loadingPillShows, loading_pill_long_shows: counts.loadingPillLongShows, loading_pill_skips: counts.loadingPillSkips,
      new_tab_bar_keeps: counts.newTabBarKeeps, new_tab_bar_launch_shows: counts.newTabBarLaunchShows, new_tab_lingers: counts.newTabLingers, new_tab_lingers_late: counts.newTabLingersLate, new_tab_leaves_for_webkit: counts.newTabLeavesForWebKit, new_tab_leaves_without_linger: counts.newTabLeavesWithoutLinger, bar_split_opens: counts.barSplitOpens, bar_split_full_tabs: counts.barSplitFullTabs, split_suggestion_key_picks: counts.splitSuggestionKeyPicks,
      dock_reopens: counts.dockReopens, dock_reopens_past_floating: counts.dockReopensPastFloating, pip_activation_returns: counts.pipActivationReturns, pip_activation_return_failures: counts.pipActivationReturnFailures, webkit_pages_kept_hidden: counts.webKitPagesKeptHidden,
      settings_search_keyboard_reveals: counts.settingsSearchKeyboardReveals, settings_search_click_reveals: counts.settingsSearchClickReveals, settings_searches: counts.settingsSearches, settings_searches_empty: counts.settingsSearchesEmpty, settings_searches_dropped: counts.settingsSearchesDropped, settings_search_top_picks: counts.settingsSearchTopPicks, webkit_limits_opens_engine_row: counts.webKitLimitsFromEngineRow, webkit_limits_opens_engines_pane: counts.webKitLimitsFromEnginesPane, settings_search_top3_picks: counts.settingsSearchTop3Picks, settings_search_lower_picks: counts.settingsSearchLowerPicks, settings_search_unshown_reveals: counts.settingsSearchUnshownReveals, shortcuts_key_searches_typed: counts.shortcutsKeySearchesTyped, shortcuts_key_searches_recorded: counts.shortcutsKeySearchesRecorded, shortcuts_key_searches_empty: counts.shortcutsKeySearchesEmpty, settings_search_key_searches: counts.settingsSearchKeySearches, settings_search_key_hit_opens: counts.settingsSearchKeyHitOpens,
      auto_pip_kept_visible: counts.autoPictureInPictureKept, auto_pip_stayed_on_app_switch: counts.autoPictureInPictureStayedOnAppSwitch, selection_close_keys: counts.selectionCloseKeys, selection_close_key_tabs: counts.selectionCloseKeyTabs,
      onboarding_imports: counts.onboardingImports, onboarding_helium_imports: counts.onboardingHeliumImports, onboarding_listed_only_imports: counts.onboardingListedOnlyImports, onboarding_glass_picks: counts.onboardingGlassPicks, onboarding_classic_picks: counts.onboardingClassicPicks, onboarding_tinted_glass_picks: counts.onboardingTintedGlassPicks, onboarding_steps_completed: counts.onboardingStepsCompleted, onboarding_steps_skipped: counts.onboardingStepsSkipped, onboarding_redo_opened: counts.onboardingRedoOpened, onboarding_redo_completed: counts.onboardingRedoCompleted, onboarding_redo_cancelled: counts.onboardingRedoCancelled, onboarding_preset_kept_imports: counts.onboardingPresetKeptImports,
      update_channel_switches: counts.updateChannelSwitches, update_channel_switch_offers: counts.updateChannelSwitchOffers, update_channel_switch_up_to_date: counts.updateChannelSwitchUpToDate, update_channel_switch_check_failures: counts.updateChannelSwitchCheckFailures, clean_up_suggestion_shows: counts.cleanUpSuggestionShows, clean_up_suggestion_once: counts.cleanUpSuggestionOnce, clean_up_suggestion_daily: counts.cleanUpSuggestionDaily, clean_up_suggestion_not_now: counts.cleanUpSuggestionNotNow, clean_up_suggestion_never_again: counts.cleanUpSuggestionNeverAgain, clean_up_undos: counts.cleanUpUndos, link_tabs_matched: counts.linkTabsMatched, link_tab_waits_skipped: counts.linkTabWaitsSkipped, link_tab_wait_timeouts: counts.linkTabWaitTimeouts, history_search_focus_requests: counts.historySearchFocusRequests, history_search_focused: counts.historySearchFocused, period_minutes: Math.round((Date.now() - countsSince) / 60_000),
    }, consent);
  }
  counts = { ...NO_COUNTS };
  countsSince = Date.now();
}

watchConsentBoundary(() => emitWindowUsage(null));
export const noteImportedPins = (made: { rows: number; splits: number }, consent?: ConsentToken | null) => bump(consent, { importedPinnedRows: made.rows, importedSplits: made.splits });

export const noteImportedSpaces = (made: { spaces: number; containerSpaces: number; dataProfiles: number; essentials: number; startersNamed: number }, consent?: ConsentToken | null) => bump(consent, { importedSpaces: made.spaces, importedContainerSpaces: made.containerSpaces, importedDataProfiles: made.dataProfiles, importedEssentials: made.essentials, importedStartersNamed: made.startersNamed });

export const noteOnboardingImport = (source: string) => void (counts.onboardingImports++, source === "helium" && counts.onboardingHeliumImports++, ["chromium", "vivaldi", "opera"].includes(source) && counts.onboardingListedOnlyImports++);

export const noteOnboarding = (event: "stepCompleted" | "stepSkipped" | "redoOpened" | "redoCompleted" | "redoCancelled" | "presetKeptImport") => void counts[(({ stepCompleted: "onboardingStepsCompleted", stepSkipped: "onboardingStepsSkipped", redoOpened: "onboardingRedoOpened", redoCompleted: "onboardingRedoCompleted", redoCancelled: "onboardingRedoCancelled", presetKeptImport: "onboardingPresetKeptImports" }) as const)[event]]++;

export const noteOnboardingStyle = (style: "glass" | "classic", tinted: boolean) => void (counts[style === "glass" ? "onboardingGlassPicks" : "onboardingClassicPicks"]++, style === "glass" && tinted && counts.onboardingTintedGlassPicks++);

export const noteSplit = (count: "splitPaneCloses" | "splitViewCloses" | "splitDividerResets" | "barSplitOpens" | "barSplitFullTabs" | "splitSuggestionKeyPicks", consent?: ConsentToken | null) => bump(consent, { [count]: 1 });
export const noteBackCloseToOpener = () => void counts.backClosesToOpener++;

export const noteWindowCloseTabsKept = (n: number) => void (counts.windowCloseTabsKept += n);

export const noteSelectionClosedByKey = (tabs: number) => void ((counts.selectionCloseKeys += 1), (counts.selectionCloseKeyTabs += tabs));

export const noteSharePicked = (kind: "tab" | "window" | "screen", withController = false, consent?: ConsentToken | null) =>
  bump(consentOrNow(consent), { [kind === "tab" ? "sharesPickedTab" : kind === "window" ? "sharesPickedWindow" : "sharesPickedScreen"]: 1, sharesWithCaptureController: withController ? 1 : 0 });

export const noteScreenRecordingMissing = () => counts.screenRecordingMissing++;
export const noteScreenRecordingAsked = () => counts.screenRecordingAsked++;

export const noteWebKitPageKeptHidden = () => counts.webKitPagesKeptHidden++;
export const noteAutoPictureInPictureKept = (reason: "onScreen" | "appSwitch" | "nothingPlaying", epoch: string) =>
  counted(nativeConsent({ epoch }), () => (reason === "nothingPlaying" ? noteAutoPictureInPictureNothingPlaying() : counts[reason === "appSwitch" ? "autoPictureInPictureStayedOnAppSwitch" : "autoPictureInPictureKept"]++));

export const noteExtensionInstallPrompt = () => counts.extensionInstallPrompts++;
export const noteExtensionInstallPromptStale = (consent?: ConsentToken | null) => bump(consent, { extensionInstallPromptsStale: 1 });
export const noteExtensionProfilePageOpen = (rerouted: boolean) => void (counts.extensionProfilePageOpens++, rerouted && counts.extensionProfilePageReroutes++), notePrivateWindowExtensionOpen = () => counts.privateWindowExtensionOpens++, noteSidePanelKept = () => counts.sidePanelsKeptOnSwitch++;
export const noteToolbarAnchor = (outcome: "moved" | "missed", consent?: ConsentToken | null) => bump(consent, { [outcome === "moved" ? "toolbarAnchorMoves" : "toolbarAnchorMisses"]: 1 });
export const noteEmptyTabSidebarExtensionPress = () => counts.emptyTabSidebarExtensionPresses++;
export const noteToolbarExtensionMove = (via: "drag" | "menu") => void (counts.toolbarExtensionMoves++, via === "menu" && counts.toolbarExtensionMenuMoves++);

export const noteContentBlockerUnavailable = () => counts.contentBlockerUnavailable++;
export const noteContentBlockerWriteFailure = (consent?: ConsentToken | null) => bump(consent, { contentBlockerWriteFailures: 1 }), noteBlockedPageBehind = () => counts.contentBlockerPagesBehind++;
const CUSTOM_FILTER_LIST = { added: "contentBlockerCustomListsAdded", addFailed: "contentBlockerCustomListAddFailures", removed: "contentBlockerCustomListsRemoved" } as const;
export const noteCustomFilterList = (event: keyof typeof CUSTOM_FILTER_LIST, consent: ConsentToken | null) =>
  counted(consent, () => void counts[CUSTOM_FILTER_LIST[event]]++);

export const noteCliEdits = (tabEdits: number, groupEdits: number, failures: number, consent?: ConsentToken | null) => bump(consent, { cliTabEdits: tabEdits, cliGroupEdits: groupEdits, cliEditFailures: failures });

const OVERLAY_COUNTS = { newTabShown: "newTabNoticesShown", peekMovedCard: "sidebarPeekCardMoves", newTabPressed: "newTabNoticePresses", selectedRowPillShown: "selectedRowPillShows", selectedRowPillPressed: "selectedRowPillPresses", statusAtTop: "statusBubbleTopShows", newTabBarKept: "newTabBarKeeps", newTabBarOnLaunch: "newTabBarLaunchShows", newTabLingered: "newTabLingers", newTabLingerLate: "newTabLingersLate", newTabLeftForWebKit: "newTabLeavesForWebKit", newTabLeftWithoutLinger: "newTabLeavesWithoutLinger", loadingField: "loadingFieldShows", loadingPill: "loadingPillShows", loadingPillLong: "loadingPillLongShows", loadingSkipped: "loadingPillSkips", peekShownAgain: "peeksShownAgain" } as const;
export const notePageOverlay = (event: keyof typeof OVERLAY_COUNTS, consent?: ConsentToken | null) => bump(consent, { [OVERLAY_COUNTS[event]]: 1 });

export const notePopoverClosed = (by: "press" | "escape") => void counts[by === "press" ? "popoverPressCloses" : "popoverEscapeCloses"]++;
export const noteSiteControls = (event: "autoplayBlock" | "autoplayAllow" | "autoplayPlaysBlocked" | "siteSettings" | "manageExtensions" | "sidebarField", times = 1, consent?: ConsentToken | null) => bump(consent, { [(({ autoplayBlock: "siteAutoplayBlocks", autoplayAllow: "siteAutoplayAllows", autoplayPlaysBlocked: "autoplayPlaysBlocked", siteSettings: "siteSettingsOpens", manageExtensions: "siteManageExtensionsOpens", sidebarField: "sidebarFieldSiteControlsOpens" }) as const)[event]]: times });

export const noteCleanUp = (event: "suggestionShown" | "suggestionOnce" | "suggestionDaily" | "suggestionNotNow" | "suggestionNeverAgain" | "undone") => void counts[(({ suggestionShown: "cleanUpSuggestionShows", suggestionOnce: "cleanUpSuggestionOnce", suggestionDaily: "cleanUpSuggestionDaily", suggestionNotNow: "cleanUpSuggestionNotNow", suggestionNeverAgain: "cleanUpSuggestionNeverAgain", undone: "cleanUpUndos" }) as const)[event]]++;
export const noteUpdateChannelSwitch = (outcome: "offered" | "upToDate" | "failed" | null, consent?: ConsentToken | null) => bump(consent, { updateChannelSwitches: 1, ...(outcome && { [outcome === "offered" ? "updateChannelSwitchOffers" : outcome === "upToDate" ? "updateChannelSwitchUpToDate" : "updateChannelSwitchCheckFailures"]: 1 }) });

export const noteTabSwitcherOpened = (closedLeftOut: number, unseenLast: number) =>
  void (counts.tabSwitcherOpens++, (counts.tabSwitcherClosedLeftOut += closedLeftOut), (counts.tabSwitcherUnseenLast += unseenLast));

export const noteApprovalNoticeDeferred = () => counts.approvalNoticesDeferred++;

export const noteDockReopen = (pastFloating: boolean) => void (counts.dockReopens++, pastFloating && counts.dockReopensPastFloating++);
export const notePiPActivationReturn = (success: boolean, consent?: ConsentToken | null) => bump(consent, { pipActivationReturns: 1, pipActivationReturnFailures: success ? 0 : 1 });
export function noteReopenedPage(canGoBack: boolean) {
  counts.reopenedPages++;
  if (canGoBack) counts.reopenedPagesWithBack++;
}

export const noteToolbarPageHidden = (during: "peek" | "motion" | null) => void (during && counts[during === "peek" ? "toolbarPeekPageHides" : "toolbarMotionPageHides"]++);
export const noteSidebarPeekPageHidden = () => void counts.sidebarPeekPageHides++;
export const noteSidebarEmptyWindowPeek = () => void counts.sidebarEmptyWindowPeeks++;
export const notePinch = (on: "peek" | "littleArdia", outcome: "open" | "close") => void counts[on === "peek" ? (outcome === "open" ? "peekPinchOpens" : "peekPinchCloses") : outcome === "open" ? "littleArdiaPinchOpens" : "littleArdiaPinchCloses"]++;

export const noteSwipeClose = (closed: boolean) => void counts[closed ? "littleArdiaSwipeCloses" : "littleArdiaSwipeCloseCancels"]++;
export const noteExternalLink = (opened: "tab" | "littleArdia", settingOn: boolean) => void counts[opened === "tab" ? (settingOn ? "externalLinksTabSettingOn" : "externalLinksTabSettingOff") : settingOn ? "externalLinksLittleSettingOn" : "externalLinksLittleSettingOff"]++;

export const noteGroupHeaderHide = () => counts.groupHeaderHides++;

export const noteLinkTabWait = (wait: "matched" | "skipped" | "timedOut") => void counts[wait === "matched" ? "linkTabsMatched" : wait === "skipped" ? "linkTabWaitsSkipped" : "linkTabWaitTimeouts"]++;

export const noteHistorySearchFocus = (step: "requested" | "focused") => void counts[step === "requested" ? "historySearchFocusRequests" : "historySearchFocused"]++;

export const noteSidebarMotion = (what: "merge" | "overrun") => void counts[what === "merge" ? "sidebarMotionMerges" : "sidebarSlideOverruns"]++;

export const noteCardResizeLayout = (applied: boolean) => counts[applied ? "cardResizeLayoutsApplied" : "cardResizeLayouts"]++;

export function noteSidebarPeek(bounce: boolean) {
  counts.sidebarPeeks++;
  if (bounce) counts.sidebarPeekBounces++;
  if (!useBrowser.getState().settings.autoHideTabs) counts.tabPeeksWithAutoHideOff++;
}

export const noteSettingsSearchReveal = (via: "keyboard" | "click", rank: number, unshown: boolean) => void (counts[via === "keyboard" ? "settingsSearchKeyboardReveals" : "settingsSearchClickReveals"]++, counts[rank === 0 ? "settingsSearchTopPicks" : rank < 3 ? "settingsSearchTop3Picks" : "settingsSearchLowerPicks"]++, unshown && counts.settingsSearchUnshownReveals++);

export const noteSettingsSearch = (event: "started" | "empty" | "dropped" | "keys" | "keysOpened" | "shortcutsTyped" | "shortcutsRecorded" | "shortcutsEmpty", consent?: ConsentToken | null) => bump(consent, { [({ started: "settingsSearches", empty: "settingsSearchesEmpty", dropped: "settingsSearchesDropped", keys: "settingsSearchKeySearches", keysOpened: "settingsSearchKeyHitOpens", shortcutsTyped: "shortcutsKeySearchesTyped", shortcutsRecorded: "shortcutsKeySearchesRecorded", shortcutsEmpty: "shortcutsKeySearchesEmpty" } as const)[event]]: 1 });
export const noteWebKitLimits = (event: "engineRow" | "enginesPane") => void counts[({ engineRow: "webKitLimitsFromEngineRow", enginesPane: "webKitLimitsFromEnginesPane" } as const)[event]]++;

export const noteTabStripPeek = () => void (counts.tabStripPeeks++, !useBrowser.getState().settings.autoHideTabs && counts.tabPeeksWithAutoHideOff++);
export const noteTabStripMenu = (menu: "tabs" | "overflow") => void counts[menu === "tabs" ? "tabStripMenuOpens" : "tabStripOverflowOpens"]++;
const size = (o: object) => keysOf(o).length;

function watchStore() {
  let tabCount = size(useBrowser.getState().tabs);
  let windowCount = size(useBrowser.getState().windows);
  useBrowser.subscribeTo(["tabs", "windows", "groups", "splits", "windowUi"], (s, prev) => {
    if (s.tabs !== prev.tabs) {
      const now = size(s.tabs);
      counts.tabs += Math.max(0, now - tabCount);
      tabCount = now;
    }
    if (s.windows !== prev.windows) {
      const now = size(s.windows);
      counts.windows += Math.max(0, now - windowCount);
      windowCount = now;
      for (const id in s.windows) {
        const w = s.windows[id]!;
        const before = prev.windows[id];
        if (before && !before.fullScreen && w.fullScreen) counts.fullScreens++;
        if (before && before.profileId !== w.profileId && w.kind !== "private") profileSwitched(id, before.profileId, w.profileId, size(s.profiles), switcherSwitchProperties(id, w.profileId));
      }
    }
    if (s.groups !== prev.groups) counts.groupTabsKept += keptTabsAdded(s.groups, prev.groups);
    if (s.splits !== prev.splits) {
      for (const id in s.splits) if (!prev.splits[id]) capture("split_view_opened", { panes: splitTabIds(s.splits[id]!).length }, consentNow());
    }
    if (s.windowUi !== prev.windowUi) {
      for (const id in s.windowUi) if (s.windowUi[id]?.panel.open && !prev.windowUi[id]?.panel.open) capture("command_bar_opened", { placement: commandBarPlacementLabel(s.windowUi[id]!.panel) }, consentNow());
    }
  });
}

function watchToolbarAutoHide() {
  const bounces = toolbarBounces((id) => !!useBrowser.getState().tabs[id]);
  useToolbarAutoHide.subscribe((s, prev) => {
    if (s.peek !== prev.peek) for (const id in s.peek) if (!prev.peek[id]) counts.toolbarPeeks++;
    if (s.scrolledDown === prev.scrolledDown) return;
    const seen = bounces.note(s.scrolledDown, prev.scrolledDown);
    counts.toolbarScrollHides += seen.hides;
    counts.toolbarScrollHideBounces += seen.bounces;
  });
}

function watchSync() {
  let last = useSync.getState().status;
  useSync.subscribe(({ status }) => {
    const was = last;
    last = status;
    if (was === status) return;
    if (was === "off" && status !== "unavailable") capture("sync_toggled", { on: true }, consentNow());
    else if (status === "off" && was !== "unavailable") capture("sync_toggled", { on: false }, consentNow());
  });
}

function watchTranslate() {
  useTranslate.subscribe((s, prev) => {
    for (const tabId in s) if (s[tabId]?.status === "translating" && prev[tabId]?.status !== "translating") capture("translate_used", {}, consentNow());
  });
}



const mb = (bytes: number) => Math.round(bytes / 1_048_576);

async function sampleMemory(consent: ConsentToken | null) {
  if (!stillValid(consent)) return;
  try {
    await listTasks().catch((): EngineTask[] => []);
    await new Promise((resolve) => setTimeout(resolve, 2000));
    const tasks = await listTasks().catch((): EngineTask[] => []);
    let total = 0, browser = 0, gpu = 0, renderers = 0;
    for (const t of tasks) {
      const m = Math.max(0, t.memory);
      total += m;
      if (t.type === "browser") browser += m;
      else if (t.type === "gpu") gpu += m;
      else if (t.type === "renderer") renderers++;
    }
    if (!total || !stillValid(consent)) return;
    noteAppMemory(mb(total));
    const mainProcessWork = await takeMainProcessWork();
    const contentDrift = await takeContentDriftCounts();
    const coldTabHolds = await takeColdTabHoldCounts();
    capture("perf_memory", { ...mainProcessWork, ...contentDrift, ...takeFreezeCounts(consent), ...coldTabHolds,
      total_mb: mb(total),
      browser_mb: mb(browser),
      gpu_mb: mb(gpu),
      renderer_processes: renderers,
      tabs: size(useBrowser.getState().tabs),
      uptime_hours: Math.round((Date.now() - startedAt) / HOUR_MS),
    }, consent);
  } catch {}
}

function emitOmniboxLatency(consent: ConsentToken | null) {
  const samples = takeOmniboxLatency().sort((a, b) => a - b);
  if (!samples.length) return void (stillValid(consent) || takeSearchSuggests());
  const at = (p: number) => percentile(samples, p);
  capture("perf_omnibox", { ...takeSearchSuggests(), samples: samples.length, p50_ms: at(0.5), p95_ms: at(0.95), max_ms: samples.at(-1)! }, consent);
}

function snapshotSettings(consent: ConsentToken | null) {
  const today = utcDay(Date.now()), passwordManagers = passwordManagerSnapshot();
  if (settingsSnapshotDay() === today || !passwordManagers) return;
  const state = useBrowser.getState();
  const settings = { ...settingsSnapshot(state.settings), ...customColorProfiles(state.profiles, state.settings.defaultProfileId), ...openTabSyncProfiles(state.profiles), ...narrowWindows(state.windows, state.settings.sidebarWidth), ...airTrafficSnapshot(), ...currentThemeFileSnapshot(), ...pluginsSnapshot(), ...passwordManagers };
  void Promise.all([currentAppIcon().catch(() => null), listComponents().catch(() => null)]).then(([icon, components]) => (capture(SETTINGS_SNAPSHOT_EVENT, { ...settings, ...appIconSetting(icon), ...widevineSetting(components) }, consent), stillValid(consent) && markSettingsSnapshot(today)));
}

let previousContext: SavedContext | null = null;
let launchCrashRead: ReturnType<typeof setTimeout> | undefined;

function hourly() {
  snapshotSettings(consentToken());
  emitWindowUsage(consentNow());
  emitJourneys();
  void sampleMemory(consentToken());
  void reportNativeCrashes([previousContext, ...contextSamples()]).then(() => recordContext());
  void reportLocalStore(consentToken());
}

export function startUsage(continuing = false) {
  const session = startClient(continuing);
  previousContext = session.context;
  releaseTopAppsSharing();
  if (!continuing) void launchEvents(session, consentToken());
  if (!continuing) launchCrashRead = setTimeout(() => void reportNativeCrashes([previousContext]), session.previous === "unclean" ? 1000 : 5000);
  startWatchChecks();
  startLocalStore(LOCAL_STORE_LAUNCH_DELAY_MS);
  startContextSamples();
  startJourneys(isSharing() && !continuing ? session : null);
  counts.windowsRealignedToAutoHideTabs = windowsRealignedToAutoHideTabsAtLaunch();
  watchStore();
  watchToolbarAutoHide();
  watchSync();
  watchTranslate();
  watchExtensionInstalls(startedAt);
  watchEngineReports();
  watchPopupProtectedMedia();
  setTimeout(() => void sampleMemory(consentToken()), FIRST_MEMORY_SAMPLE_MS);
  setTimeout(() => snapshotSettings(consentToken()), FIRST_SETTINGS_SNAPSHOT_MS);
  setInterval(hourly, HOUR_MS);
  onAppEvent((e) => {
    if (e.type === "pipActivationReturn") notePiPActivationReturn(e.success, nativeConsent(e));
    else if (e.type === "willQuit") {
      clearTimeout(launchCrashRead);
      stopContextSamples();
      sessionEnding();
    } else if (e.type === "quitCancelled") startContextSamples();
  });
}

export const emitWindowUsage = (consent: ConsentToken | null) => [() => withHourlyExtras(() => emitCounts(consent), consent), () => emitOmniboxLatency(consent), () => emitTabPresses(consent)].forEach((emit) => emit());

export function sessionEnding() {
  emitWindowUsage(consentNow());
  journeysEnding();
  capture("app_session_ended", { duration_minutes: Math.round((Date.now() - startedAt) / 60_000) }, consentNow());
  endSession();
}

export async function devHourly() {
  hourly();
  await new Promise((resolve) => setTimeout(resolve, 2500));
  await flush();
}
