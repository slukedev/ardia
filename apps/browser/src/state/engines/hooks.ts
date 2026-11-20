import { useBrowser } from "../browser/store";
import type { PageEngine } from "../../platform/tabs";
import { builtInEngine, engineMode, recommendedEngineFor, ruleFor, singleEngine, switchableEngine, tabEngine, type EngineMode } from "./engines";
import { useRetiringPages } from "./engineSwap";
import { useEngineModeSwitch } from "./actions";

export const usePageEngine = (tabId: string) => useBrowser((s) => tabEngine(s, tabId));

export const useEngineRule = (url: string | undefined | null) => useBrowser((s) => ruleFor(s, url));

export const useRecommendedEngine = (url: string | undefined | null) => useBrowser((s) => recommendedEngineFor(s, url));

export const useStreamingSite = (url: string | undefined | null) => useBrowser((s) => !!builtInEngine(s, url));

export const useSingleEngine = () => useBrowser((s) => singleEngine(s));

export const useCanSwitchEngine = (url: string | undefined | null) => useBrowser((s) => switchableEngine(s, url));

export function useEngineMode(): { mode: EngineMode; switching: boolean } {
  const saved = useBrowser((s) => engineMode(s));
  const pending = useEngineModeSwitch((s) => s.pending);
  return { mode: pending ?? saved, switching: pending !== null };
}

export const useRetiringEngine = (tabId: string, engine: PageEngine): PageEngine | null =>
  useRetiringPages((pages) => (pages[tabId] && pages[tabId].engine !== engine ? pages[tabId].engine : null));
