import { exportWebKitCookies, importWebKitCookies, webKitCookieStoreKey } from "../../platform/webkit";
import type { PageEngine, WebViewHandle } from "../../platform/tabs";
import { useBrowser } from "../browser/store";
import { tabEngine } from "./engines";
import { engineProfile, isIncognitoProfile } from "../browser/model";
import { carriableCookies, cookieAddresses } from "./signInCookies";
import { webviews } from "../../platform/webviews";
import { withDeadline } from "../../lib/deadline";
import { noteCookiesCarried } from "../telemetry/engineSwitchCounts";

const CARRY_DEADLINE_MS = 1500;

function stillPage(tabId: string, profile: string, web: WebViewHandle, engine: PageEngine) {
  const s = useBrowser.getState();
  const t = s.tabs[tabId];
  return !!t && engineProfile(s, t.profileId) === profile && webviews.get(tabId) === web && tabEngine(s, tabId) === engine;
}

async function copyToWebKit(tabId: string, url: string): Promise<number> {
  const t = useBrowser.getState().tabs[tabId];
  const web = webviews.get(tabId);
  const urls = cookieAddresses(url);
  if (!t || !web || !urls.length) return 0;
  const profile = engineProfile(useBrowser.getState(), t.profileId);
  if (!stillPage(tabId, profile, web, "chromium")) return 0;
  const storeKey = await webKitCookieStoreKey(profile);
  if (storeKey == null || !stillPage(tabId, profile, web, "chromium")) return 0;
  const cookies = carriableCookies(await web.pageCookies(urls), Date.now() / 1000);
  if (!cookies.length || !stillPage(tabId, profile, web, "chromium")) return 0;
  return importWebKitCookies(profile, storeKey, cookies);
}

async function copyToChromium(tabId: string, url: string): Promise<number> {
  const t = useBrowser.getState().tabs[tabId];
  const web = webviews.get(tabId);
  const urls = cookieAddresses(url);
  if (!t || !web || !urls.length || isIncognitoProfile(t.profileId)) return 0;
  const profile = engineProfile(useBrowser.getState(), t.profileId);
  if (!stillPage(tabId, profile, web, "webkit")) return 0;
  return exportWebKitCookies(profile, urls);
}

export function carrySignIn(tabId: string, url: string, to: PageEngine): Promise<number> {
  const copy = to === "webkit" ? copyToWebKit(tabId, url) : copyToChromium(tabId, url);
  return withDeadline(
    copy.catch(() => 0).then((count) => (noteCookiesCarried(to, count), count)),
    CARRY_DEADLINE_MS,
    0,
  );
}

export const carrySignInToWebKit = (tabId: string, url: string) => carrySignIn(tabId, url, "webkit");
