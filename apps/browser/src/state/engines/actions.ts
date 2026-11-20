import { addHistoryVisits } from "../../platform/history";
import type { PageEngine, ProtectedMediaRequest } from "../../platform/tabs";
import { confirm } from "../../platform/dialogs";
import { create } from "zustand";
import { storeTransaction, useBrowser } from "../browser/store";
import { pageOf, patchPage } from "../tabs/pageState";
import {
  canSwitchEngine,
  chosenEngine,
  chromiumOnly,
  drivenByChrome,
  ENGINE_NAMES,
  engineMode,
  engineUnderMode,
  modeEngineFor,
  needsChromium,
  singleEngine,
  siteOf,
  tabEngine,
  visitRecorder,
  webStorePage,
  type EngineMode,
  type WebKitPage,
} from "./engines";
import { engineProfile, isIncognitoProfile, navigationTo } from "../browser/model";
import type { Tab } from "../browser/types";
import { carrySignInToWebKit, signInCarryOn } from "./engineSignIn";
import { dropSwap, holdPageForSwap } from "./engineSwap";
import { wantsPage } from "../tabs/tabPages";
import { webviews } from "../../platform/webviews";
import { withDeadline } from "../../lib/deadline";
import { loadedPage, navigationOf } from "../tabs/pageSession";
import { noteEngineModeChange, noteEngineModeVideoNotice } from "../telemetry/engineSwitchCounts";
import { consentToken } from "../telemetry/client";
import { showToast } from "../app/toasts";
import { openSettings } from "../settings/settingsWindows";
import { PLATFORM_FEATURES } from "../../lib/platformFeatures";

export type EngineOffer = { site: string; host: string; keySystem: string; canRemember: boolean };

export const useEngineOffers = create<Record<string, EngineOffer>>()(() => ({}));

const store = () => useBrowser.getState();
const declinedSites = new Set<string>();
const toldInChromiumMode = new Set<string>();
const movingTabs = new Set<string>();
const siteMoves = new Map<string, number>();
const SITE_MOVE_SPACING_MS = 10_000;
const hostLabel = (site: string) => new URL(site).hostname.replace(/^www\./, "");

export const useEngineModeSwitch = create<{ pending: EngineMode | null }>()(() => ({ pending: null }));

let modeGeneration = 0;

function modeStillHolds(): () => boolean {
  const generation = modeGeneration;
  const mode = engineMode(store());
  return () => generation === modeGeneration && engineMode(store()) === mode && !useEngineModeSwitch.getState().pending;
}

const UNSAVED_WORK = `(() => {
  const fields = Array.from(document.querySelectorAll("input:not([type=hidden]):not([type=password]):not([type=submit]):not([type=button]), textarea, select"));
  const changed = (f) => f.type === "checkbox" || f.type === "radio" ? f.checked !== f.defaultChecked : f.tagName === "SELECT" ? Array.from(f.options).some((o) => o.selected !== o.defaultSelected) : f.value !== f.defaultValue;
  const editing = document.activeElement && document.activeElement.isContentEditable;
  post("result", JSON.stringify(fields.some(changed) || !!editing));
})()`;

async function hasUnsavedWork(tabId: string): Promise<boolean> {
  const web = webviews.get(tabId);
  if (!web) return false;
  return (await withDeadline(web.evaluate<boolean>(UNSAVED_WORK), 1500, null)) === true;
}

export function setWebsiteEngine(url: string, engine: PageEngine | null) {
  const site = siteOf(url);
  if (!site) return;
  const rules = { ...store().settings.websiteEngines };
  if (engine) rules[site] = engine;
  else delete rules[site];
  store().updateSettings({ websiteEngines: rules });
}

export function persistEngine(tabId: string, engine: PageEngine) {
  const s = store();
  const t = s.tabs[tabId];
  if (!t) return;
  const opened = engine === "chromium" && !t.chromeOpened && drivenByChrome(s, t);
  if (!t.engine || opened) s.updateTab(tabId, { ...(t.engine ? {} : { engine }), ...(opened ? { chromeOpened: true as const } : {}) });
}

const asksAboutUnsavedWork = () => store().settings.engineSwitchAsksAboutUnsavedWork;

async function mayLeavePage(t: Tab, title: string, message: string, confirmTitle: string, ask: typeof confirm = confirm): Promise<boolean> {
  if (!wantsPage(t) || !asksAboutUnsavedWork() || !(await hasUnsavedWork(t.id))) return true;
  const { confirmed } = await ask({ title, message, confirmTitle, cancelTitle: "Stay on Page", windowId: t.windowId });
  return confirmed;
}

const pageUrl = (t: Tab | undefined) => t?.url || navigationOf(t)?.url || "";

export async function goBackAcrossEngines(tabId: string, mayAct: () => boolean = () => true, ask: typeof confirm = confirm): Promise<boolean> {
  const back = pageOf(tabId).engineBack;
  const t = store().tabs[tabId];
  if (!back || !t) return false;
  const forced = modeEngineFor(store(), t, back.url);
  if (forced && forced !== back.engine) {
    patchPage(tabId, { engineBack: null });
    return false;
  }
  const from = pageUrl(t);
  const holds = modeStillHolds();
  const leaving = await mayLeavePage(t, "Go back to the previous page?", `It opens in ${ENGINE_NAMES[back.engine]}, so changes you made on this page may not be saved.`, "Go Back", ask);
  const now = store().tabs[tabId];
  if (!leaving || !holds() || !now || pageUrl(now) !== from || pageOf(tabId).engineBack !== back || !mayAct()) return false;
  patchPage(tabId, { engineBack: null });
  const held = await holdPageForSwap(tabId, tabEngine(store(), tabId), back.engine, back.url, false, holds);
  if (!holds() || pageUrl(store().tabs[tabId]) !== from) {
    dropSwap(tabId, held);
    return false;
  }
  store().updateTab(tabId, { engine: back.engine, page: loadedPage(navigationTo(back.url, true)) });
  return true;
}

type MoveOptions = { rule?: PageEngine | null; checkWork?: boolean; mayWrite?: () => boolean };

const switchingTabs = new Set<string>();

export async function openPageIn(tabId: string, engine: PageEngine, options: MoveOptions = {}): Promise<boolean> {
  if (switchingTabs.has(tabId)) return false;
  switchingTabs.add(tabId);
  try {
    return await movePage(tabId, engine, options);
  } finally {
    switchingTabs.delete(tabId);
  }
}

async function movePage(tabId: string, engine: PageEngine, options: MoveOptions): Promise<boolean> {
  const t = store().tabs[tabId];
  if (!t) return false;
  const url = t.url || navigationOf(t)?.url || "";
  if (!canSwitchEngine(url) && !(engine === "chromium" && webStorePage(url))) return false;
  const forced = modeEngineFor(store(), t, url);
  if (forced && forced !== engine) return false;
  const saveRule = () => options.rule !== undefined && !isIncognitoProfile(t.profileId) && setWebsiteEngine(url, options.rule);
  clearEngineOffer(tabId);
  if (tabEngine(store(), tabId) === engine) {
    saveRule();
    return true;
  }
  const holds = modeStillHolds();
  if (options.checkWork !== false && !(await mayLeavePage(t, `Open this page in ${ENGINE_NAMES[engine]}?`, `The page reloads in ${ENGINE_NAMES[engine]}, so changes you made on it may not be saved.`, `Open in ${ENGINE_NAMES[engine]}`))) return false;
  if (!holds()) return false;
  if (engine === "webkit" && signInCarryOn()) await carrySignInToWebKit(tabId, url);
  if (!holds()) return false;
  const from = tabEngine(store(), tabId);
  const held = from !== engine && wantsPage(store().tabs[tabId]) ? await holdPageForSwap(tabId, from, engine, url, true, holds) : null;
  const now = store().tabs[tabId];
  if (!holds() || !now || pageUrl(now) !== url || (options.mayWrite && !options.mayWrite())) {
    dropSwap(tabId, held);
    return false;
  }
  saveRule();
  if (tabEngine(store(), tabId) === engine) {
    dropSwap(tabId, held);
    return true;
  }
  store().updateTab(tabId, wantsPage(now) ? { engine, page: loadedPage(navigationTo(now.url || url, true)) } : { engine });
  return true;
}

export const togglePageEngine = (tabId: string, mayWrite?: () => boolean) => openPageIn(tabId, tabEngine(store(), tabId) === "webkit" ? "chromium" : "webkit", { mayWrite });

export function offerWebKit(tabId: string, { keySystem }: ProtectedMediaRequest) {
  const s = store();
  const t = s.tabs[tabId];
  if (!t || tabEngine(s, tabId) === "webkit") return;
  const site = siteOf(t.url);
  if (!site) return;
  if (singleEngine(s) === "chromium") return tellChromiumModeBlocks(t, site);
  if (singleEngine(s)) return;
  const rule = chosenEngine(s, t.url);
  if (rule === "chromium" || declinedSites.has(site)) return;
  if (rule === "webkit") return void moveForProtectedVideo(tabId, site);
  if (!s.settings.offerWebKitForProtectedVideo) return;
  if (useEngineOffers.getState()[tabId]?.site === site) return;
  useEngineOffers.setState({ [tabId]: { site, host: hostLabel(site), keySystem, canRemember: !isIncognitoProfile(t.profileId) } });
}

function tellChromiumModeBlocks(t: Tab, site: string) {
  if (!PLATFORM_FEATURES.webKit || toldInChromiumMode.has(site)) return;
  toldInChromiumMode.add(site);
  noteEngineModeVideoNotice("shown", consentToken());
  showToast(t.windowId, "Protected video won't play in Chromium", `${hostLabel(site)} plays in WebKit. Set Engine to Automatic or WebKit in Settings.`, {
    icon: "play.rectangle",
    key: `engine-mode-video:${site}`,
    action: {
      title: "Open Settings",
      run: () => {
        noteEngineModeVideoNotice("opened", consentToken());
        openSettings("general");
      },
    },
  });
}

export function clearEngineOffer(tabId: string) {
  if (!useEngineOffers.getState()[tabId]) return;
  useEngineOffers.setState((offers) => {
    const { [tabId]: _, ...rest } = offers;
    return rest;
  }, true);
}

export function stayOnPage(tabId: string, remember = false) {
  const offer = useEngineOffers.getState()[tabId];
  if (offer) declinedSites.add(offer.site);
  if (offer && remember && offer.canRemember) setWebsiteEngine(offer.site, "chromium");
  clearEngineOffer(tabId);
}

export const acceptEngineOffer = (tabId: string) => openPageIn(tabId, "webkit", { rule: "webkit" });

async function moveForProtectedVideo(tabId: string, site: string) {
  if (movingTabs.has(tabId)) return;
  movingTabs.add(tabId);
  try {
    if (!(await openPageIn(tabId, "webkit"))) {
      declinedSites.add(site);
      return;
    }
  } finally {
    movingTabs.delete(tabId);
  }
}

function moveAfterNavigation(tabId: string, from: PageEngine, to: PageEngine, previousUrl: string) {
  const now = Date.now();
  if (now - (siteMoves.get(tabId) ?? 0) < SITE_MOVE_SPACING_MS) return;
  siteMoves.set(tabId, now);
  watchClosedTabs();
  const holds = modeStillHolds();
  void openPageIn(tabId, to, { checkWork: false }).then((moved) => {
    if (moved && holds() && (canSwitchEngine(previousUrl) || needsChromium(previousUrl))) patchPage(tabId, { engineBack: { engine: from, url: previousUrl } });
  });
}

export function followSiteChoice(tabId: string, engine: PageEngine, url: string, previousUrl: string) {
  const s = store();
  const t = s.tabs[tabId];
  if (!t) return;
  if (singleEngine(s)) {
    const forced = modeEngineFor(s, t, url);
    const followsMode = forced === "chromium" || chromiumOnly(previousUrl) || (leftForChromium(previousUrl) && !googleSignIn(url));
    if (forced && forced !== engine && followsMode && (canSwitchEngine(url) || needsChromium(url))) moveAfterNavigation(tabId, engine, forced, previousUrl);
    return;
  }
  const site = siteOf(url);
  if (!site || site === siteOf(previousUrl) || t.openerId) return;
  const chosen = chosenEngine(s, url);
  if (chosen && chosen !== engine) moveAfterNavigation(tabId, engine, chosen, previousUrl);
}

const GOOGLE_SIGN_IN = /^https:\/\/accounts\.google\.com([/?#]|$)/i;
const googleSignIn = (url: string | undefined | null) => !!url && GOOGLE_SIGN_IN.test(url);
const leftForChromium = (url: string | undefined | null) => webStorePage(url) || googleSignIn(url);

const MODE_NAMES: Record<EngineMode, string> = { automatic: "Automatic", chromium: ENGINE_NAMES.chromium, webkit: ENGINE_NAMES.webkit };

export function modeSwitchConfirm(mode: EngineMode, unsavedPages: number, windowId?: string) {
  const pages = unsavedPages === 1 ? "A page with unsaved changes reloads" : `${unsavedPages} pages with unsaved changes reload`;
  return { title: `Switch to ${MODE_NAMES[mode]}?`, message: `${pages}, so the changes may be lost.`, confirmTitle: `Switch to ${MODE_NAMES[mode]}`, cancelTitle: "Cancel", windowId };
}

async function carryEachSite(moves: { tab: Tab; to: PageEngine; url: string }[]) {
  if (!signInCarryOn()) return;
  const carried = new Set<string>();
  await Promise.all(
    moves.map(({ tab, to, url }) => {
      const key = `${tab.profileId}|${siteOf(url)}`;
      if (to !== "webkit" || carried.has(key)) return;
      carried.add(key);
      return carrySignInToWebKit(tab.id, url);
    }),
  );
}

export async function setEngineMode(mode: EngineMode, options: { windowId?: string } = {}): Promise<boolean> {
  const before = store();
  if (useEngineModeSwitch.getState().pending || engineMode(before) === mode) return false;
  const consent = consentToken();
  useEngineModeSwitch.setState({ pending: mode });
  try {
    const target = { ...before, settings: { ...before.settings, engineMode: mode } };
    const live = Object.values(before.tabs)
      .filter((tab) => wantsPage(tab) && !!pageUrl(tab))
      .map((tab) => ({ tab, from: tabEngine(before, tab.id), to: engineUnderMode(target, tab), url: pageUrl(tab) }))
      .filter((m) => m.from !== m.to);
    const unsaved = asksAboutUnsavedWork() ? (await Promise.all(live.map((m) => hasUnsavedWork(m.tab.id)))).filter(Boolean).length : 0;
    if (unsaved > 0 && !(await confirm(modeSwitchConfirm(mode, unsaved, options.windowId))).confirmed) {
      noteEngineModeChange({ cancelled: true, moved: 0 }, consent);
      return false;
    }
    await carryEachSite(live);
    const holds = new Map(await Promise.all(live.map(async (m) => [m.tab.id, await holdPageForSwap(m.tab.id, m.from, m.to, m.url, true)] as const)));
    let moved = 0;
    storeTransaction(() => {
      const now = store();
      const next = { ...now, settings: { ...now.settings, engineMode: mode } };
      modeGeneration++;
      now.updateSettings({ engineMode: mode });
      for (const tab of Object.values(now.tabs)) {
        const from = tabEngine(now, tab.id);
        const to = engineUnderMode(next, tab);
        if (pageOf(tab.id).engineBack) patchPage(tab.id, { engineBack: null });
        if (from === to) {
          if (tab.engine && tab.engine !== to) now.updateTab(tab.id, { engine: to });
          dropSwap(tab.id, holds.get(tab.id) ?? null);
          continue;
        }
        const url = pageUrl(tab);
        moved++;
        now.updateTab(tab.id, wantsPage(tab) && url ? { engine: to, page: loadedPage(navigationTo(tab.url || url, true)) } : { engine: to });
      }
    });
    if (singleEngine(store())) useEngineOffers.setState({}, true);
    noteEngineModeChange({ cancelled: false, moved }, consent);
    return true;
  } finally {
    useEngineModeSwitch.setState({ pending: null });
  }
}

const visits = visitRecorder(
  (profile, visit) => void addHistoryVisits(profile, [{ url: visit.url, title: visit.title, visitTimes: [visit.at] }]).catch(() => {}),
  { set: (run, ms) => setTimeout(run, ms), clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>) },
  Date.now,
);

const visitedTabs = new Set<string>();
let unwatch: (() => void) | null = null;

function watchClosedTabs() {
  unwatch ??= useBrowser.subscribe((s, prev) => {
    if (s.tabs === prev.tabs) return;
    for (const id of visitedTabs) {
      if (s.tabs[id]) continue;
      visitedTabs.delete(id);
      visits.close(id);
    }
    for (const id of siteMoves.keys()) if (!s.tabs[id]) siteMoves.delete(id);
  });
}

export function noteWebKitPage(tabId: string, page: WebKitPage) {
  const t = store().tabs[tabId];
  if (!t) return;
  watchClosedTabs();
  visitedTabs.add(tabId);
  const profile = isIncognitoProfile(t.profileId) ? null : engineProfile(useBrowser.getState(), t.profileId);
  visits.note(tabId, profile, page);
}
