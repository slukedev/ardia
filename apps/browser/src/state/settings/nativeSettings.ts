import { setAppearance, setThinScrollBars } from "../../platform/app";
import { setAutoPictureInPicture, setVideoUpscaling } from "../../platform/media";
import { setCommandScrollZoom } from "../../platform/siteSettings";
import { setWebKitFraudWarnings } from "../../platform/webkit";
import { setPopupsOpenAsTabs } from "../../platform/pageOptions";
import { setBlockAutoplayEverywhere } from "../../platform/pageOptions";
import { useBrowser } from "../browser/store";
import type { Settings } from "./settings";
import { startInterfaceScale } from "./interfaceScaleSync";
import { setPressMotion } from "../../lib/pressMotion";

type Mirror = { key: keyof Settings; send: (settings: Settings) => unknown };

const mirror = <K extends keyof Settings>(key: K, send: (value: Settings[K]) => unknown): Mirror => ({ key, send: (settings) => send(settings[key]) });

const NATIVE_SETTINGS: Mirror[] = [
  mirror("appearance", setAppearance),
  mirror("autoPictureInPicture", setAutoPictureInPicture),
  mirror("videoUpscaling", setVideoUpscaling),
  mirror("webKitFraudWarnings", setWebKitFraudWarnings),
  mirror("popupsOpenAsTabs", setPopupsOpenAsTabs),
  mirror("blockAutoplayEverywhere", setBlockAutoplayEverywhere),
  mirror("pressMotion", setPressMotion),
  mirror("commandScrollZoom", setCommandScrollZoom),
];

export function startNativeSettings() {
  startInterfaceScale();
  void setThinScrollBars(false);
  const sent = new Map<keyof Settings, unknown>();
  const sync = (settings: Settings) => {
    for (const { key, send } of NATIVE_SETTINGS) {
      if (sent.has(key) && sent.get(key) === settings[key]) continue;
      sent.set(key, settings[key]);
      void send(settings);
    }
  };
  sync(useBrowser.getState().settings);
  return useBrowser.subscribeTo(["settings"], (s, prev) => s.settings !== prev.settings && sync(s.settings));
}
