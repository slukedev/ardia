import { onWebKitNotification, onWebKitNotificationClose, onWebKitOpenWindow } from "../../platform/webkit";
import { useBrowser } from "../browser/store";
import { engineProfile } from "../browser/model";
import { openFromPage } from "../tabs/openFromPage";
import { closeWebNotification, showStampedWebNotification } from "./webNotifications";
import { nativeConsent } from "../telemetry/nativeConsent";

function originOf(url: string): string | null {
  try {
    return new URL(url).origin;
  } catch {
    return null;
  }
}

function tabFor(profile: string, origin: string): string | undefined {
  const s = useBrowser.getState();
  const matching = Object.values(s.tabs).filter((tab) => {
    const window = s.windows[tab.windowId];
    return !!window && window.kind !== "private" && engineProfile(s, tab.profileId) === profile && originOf(tab.url) === origin;
  });
  const active = matching.find((tab) => s.windows[tab.windowId]?.activeTabIds[tab.profileId] === tab.id);
  return (active ?? matching[0])?.id;
}

function windowFor(profile: string): { windowId: string; profileId: string } | undefined {
  const s = useBrowser.getState();
  const ids = [...s.windowOrder, ...Object.keys(s.windows).filter((id) => !s.windowOrder.includes(id))];
  for (const id of ids) {
    const window = s.windows[id];
    if (window?.kind === "main" && engineProfile(s, window.profileId) === profile) return { windowId: id, profileId: window.profileId };
  }
  return undefined;
}

export function startWebKitNotifications() {
  onWebKitNotification((shown) => {
    const { profile, notification } = shown;
    const tabId = tabFor(profile, notification.origin);
    if (tabId) showStampedWebNotification(tabId, { ...notification, tabId }, nativeConsent(shown));
  });
  onWebKitNotificationClose(({ id }) => closeWebNotification(id));
  onWebKitOpenWindow(({ profile, ...request }) => {
    const page = windowFor(profile);
    if (page) openFromPage(request, page);
  });
}
