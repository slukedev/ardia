import { counted, onConsentPeriodChange, type ConsentToken } from "./choice";

const none = () => ({
  switches: 0,
  switchesToWebKit: 0,
  switchesHidden: 0,
  switchMsTotal: 0,
  switchMsMax: 0,
  switchTimeouts: 0,
  scrollCarried: 0,
  zoomCarried: 0,
  modeChanges: 0,
  modeChangesCancelled: 0,
  modeTabsMoved: 0,
  modeVideoNotices: 0,
  modeVideoNoticeOpens: 0,
});

let tally = none();

onConsentPeriodChange(() => (tally = none()));

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

export function takeEngineSwitchCounts() {
  const taken = tally;
  tally = none();
  return {
    engine_switches: taken.switches,
    engine_switches_to_webkit: taken.switchesToWebKit,
    engine_switches_hidden: taken.switchesHidden,
    engine_switch_ms_total: taken.switchMsTotal,
    engine_switch_ms_max: taken.switchMsMax,
    engine_switch_timeouts: taken.switchTimeouts,
    engine_switch_scroll_carried: taken.scrollCarried,
    engine_switch_zoom_carried: taken.zoomCarried,
    engine_mode_changes: taken.modeChanges,
    engine_mode_changes_cancelled: taken.modeChangesCancelled,
    engine_mode_tabs_moved: taken.modeTabsMoved,
    engine_mode_video_notices: taken.modeVideoNotices,
    engine_mode_video_notice_opens: taken.modeVideoNoticeOpens,
  };
}
