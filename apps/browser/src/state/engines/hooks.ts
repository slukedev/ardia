import { useBrowser } from "../browser/store";
import type { PageEngine } from "../../platform/tabs";
import { builtInEngine, recommendedEngineFor, ruleFor, tabEngine } from "./engines";
import { useRetiringPages } from "./engineSwap";

export const usePageEngine = (tabId: string) => useBrowser((s) => tabEngine(s, tabId));

export const useEngineRule = (url: string | undefined | null) => useBrowser((s) => ruleFor(s, url));

export const useRecommendedEngine = (url: string | undefined | null) => useBrowser((s) => recommendedEngineFor(s, url));

export const useStreamingSite = (url: string | undefined | null) => useBrowser((s) => !!builtInEngine(s, url));

export const useRetiringEngine = (tabId: string, engine: PageEngine): PageEngine | null =>
  useRetiringPages((pages) => (pages[tabId] && pages[tabId].engine !== engine ? pages[tabId].engine : null));
