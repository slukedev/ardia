import { useBrowser, type BrowserState } from "../browser/store";
import { useTab } from "../browser/hooks";
import { useKeyed } from "../browser/keyedWatch";
import { watchTabState } from "../tabs/tabStateWatch";
import { activeTabId } from "../browser/model";
import type { Tab } from "../browser/types";
import { isPageUnloaded } from "../pins/pinShare";
import { muteState, type MuteState } from "../tabs/mute";

export const ACTIVE = 1;
export const SELECTED = 2;
export const PLAYING = 4;
export const LOADING = 8;
export const FADED = 16;
const TAB_MUTED = 128;
const SITE_MUTED = 256;
export const ICON_MARKS = FADED;

export const iconMarks = (s: BrowserState, tabId: string): number => (s.settings.fadeUnloadedTabs && isPageUnloaded(s, tabId) ? FADED : 0);

export const mutedBy = (flags: number): MuteState => (flags & SITE_MUTED ? "site" : flags & TAB_MUTED ? "tab" : null);

export const useIconMarks = (tabId: string | undefined, given: number | undefined): number =>
  useKeyed(watchTabState, given === undefined ? tabId : null, () => given ?? (tabId ? iconMarks(useBrowser.getState(), tabId) : 0));

export function rowFlags(s: BrowserState, windowId: string, tabId: string): number {
  const tab = s.tabs[tabId];
  const live = s.live[tabId];
  let flags = iconMarks(s, tabId);
  if (tab && activeTabId(s, tab.windowId, tab.profileId) === tabId) flags |= ACTIVE;
  if (s.selection[windowId]?.includes(tabId)) flags |= SELECTED;
  if (live?.playingAudio) flags |= PLAYING;
  if (live?.isLoading) flags |= LOADING;
  const mute = tab ? muteState(s, tab) : null;
  if (mute) flags |= mute === "site" ? SITE_MUTED : TAB_MUTED;
  return flags;
}

export function useRowState(tabId: string, windowId: string): { tab: Tab | undefined; flags: number } {
  const tab = useTab(tabId);
  const flags = useKeyed(watchTabState, tabId, () => rowFlags(useBrowser.getState(), windowId, tabId));
  return { tab, flags };
}
