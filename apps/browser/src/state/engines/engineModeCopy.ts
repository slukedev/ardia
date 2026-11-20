import { ENGINE_NAMES, type EngineMode, type PageEngine } from "./engines";

type ModeFacts = { mode: EngineMode; switching: boolean; defaultEngine: PageEngine; streamingInWebKit: boolean };

export function engineModeFooter({ mode, switching, defaultEngine, streamingInWebKit }: ModeFacts): string {
  if (switching) return "Switching…";
  if (mode === "chromium") return "Every page opens in Chromium. Netflix and other sites with protected video won't play.";
  if (mode === "webkit") return "Pages open in WebKit, without extensions. Extension pages and the Chrome Web Store still open in Chromium.";
  const opens = `Most pages open in ${ENGINE_NAMES[defaultEngine]}.`;
  return streamingInWebKit && defaultEngine === "chromium" ? `${opens} Streaming sites open in WebKit to play protected video.` : opens;
}
