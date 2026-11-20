import { ardiaHost, hostSupports, type ArdiaHost } from "./host.ts";

export type LinuxCapabilities = {
  defaultBrowser: boolean;
  launchAtLogin: boolean;
  thinScrollBars: boolean;
  webkit: boolean;
  cliControl: boolean;
  cliInstall: boolean;
  userScripts: boolean;
  externalLinks: boolean;
  performanceRecording: boolean;
  taskManager: boolean;
  videoUpscaling: boolean;
  commandScrollZoom: boolean;
  littleArdiaNewTabLinks: boolean;
  peekOtherSites: boolean;
  popupsOpenAsTabs: boolean;
  haptics: boolean;
  linksFromOtherApps: boolean;
  dictation: boolean;
  fullScreen: boolean;
  pageEdits: boolean;
  unloadIdleProfiles: boolean;
  hiddenElements: boolean;
  blockAutoplayEverywhere: boolean;
  selfUpdate: boolean;
};

export const CLI_CONTROL_METHODS = [
  "engine.cliControlStatus",
  "engine.setCliControl",
  "engine.setCliActiveTab",
  "ArdiaAutomation.start",
  "ArdiaAutomation.stop",
  "ArdiaAutomation.reply",
  "ArdiaAutomation.broadcast",
] as const;

export const CLI_INSTALL_METHODS = ["ArdiaCli.installedVersion", "ArdiaCli.install"] as const;

export const USER_SCRIPTS_METHODS = ["ArdiaUserScripts.watch", "ArdiaUserScripts.read", "ArdiaUserScripts.readStatus", "ArdiaUserScripts.writeStatus"] as const;

export const SELF_UPDATE_METHODS = ["ArdiaUpdates.installKind", "ArdiaUpdates.update", "ArdiaUpdates.status", "ArdiaUpdates.claimOutcome", "ArdiaUpdates.restart"] as const;

export const LINKS_FROM_OTHER_APPS = "ArdiaShell.onOpenURLs";
export const DICTATION_METHOD = "ArdiaShell.startDictation";
export const FULL_SCREEN_METHOD = "ArdiaShell.toggleFullScreen";
export const FULL_SCREEN_ITEM = "std:toggleFullScreen:";
export const PAGE_EDIT_COMMAND = "tab.edit";
export const UNLOAD_IDLE_PROFILES_CALL = "profiles.unloadIdle";
export const BLOCK_AUTOPLAY_EVERYWHERE_CALL = "webView.setBlockAutoplayEverywhere";
export const HIDDEN_ELEMENTS_CALLS = ["contentBlocker.hiddenElements", "contentBlocker.hideElements", "contentBlocker.restoreElements"] as const;

export function linuxCapabilities(host: ArdiaHost | undefined = ardiaHost): LinuxCapabilities {
  const has = (...methods: string[]) => !!host && methods.every((method) => hostSupports(method, host));
  return {
    defaultBrowser: has("ArdiaSystem.isDefaultBrowser", "ArdiaSystem.setAsDefaultBrowser"),
    launchAtLogin: has("ArdiaSystem.launchAtLoginStatus", "ArdiaSystem.setLaunchAtLogin"),
    thinScrollBars: has("ArdiaSystem.setThinScrollBars"),
    webkit: false,
    cliControl: has(...CLI_CONTROL_METHODS),
    cliInstall: has(...CLI_INSTALL_METHODS),
    userScripts: has(...USER_SCRIPTS_METHODS),
    externalLinks: has("ArdiaApp.openExternalURL"),
    performanceRecording: has("engine.beginTracing", "engine.endTracing", "engine.isTracing"),
    taskManager: has("engine.openTaskManager"),
    videoUpscaling: false,
    commandScrollZoom: has("webView.setCommandScrollZoom"),
    littleArdiaNewTabLinks: has("webView.setLittleArdiaOpensNewTabLinks"),
    peekOtherSites: has("webView.setPeekOtherSiteTabs"),
    popupsOpenAsTabs: has("webView.setPopupsOpenAsTabs"),
    haptics: has("ArdiaSystem.hapticTick"),
    linksFromOtherApps: has(LINKS_FROM_OTHER_APPS),
    dictation: has(DICTATION_METHOD),
    fullScreen: has(FULL_SCREEN_METHOD),
    pageEdits: has(PAGE_EDIT_COMMAND),
    unloadIdleProfiles: has(UNLOAD_IDLE_PROFILES_CALL),
    hiddenElements: has(...HIDDEN_ELEMENTS_CALLS),
    blockAutoplayEverywhere: has(BLOCK_AUTOPLAY_EVERYWHERE_CALL),
    selfUpdate: has(...SELF_UPDATE_METHODS),
  };
}

export const WEB_ENGINE_SETTINGS = [
  "general.engineMode",
  "advanced.pageEngine",
  "advanced.websiteEngines",
  "advanced.offerWebKitForProtectedVideo",
  "advanced.engineSwitchKeepsPage",
  "advanced.engineSwitchAsksAboutUnsavedWork",
  "advanced.webKitFraudWarnings",
  "advanced.enginesDiffer",
] as const;

export function unavailableSettingIds(capabilities: LinuxCapabilities, settingIds: readonly string[]): Set<string> {
  const ids = new Set<string>();
  if (!capabilities.selfUpdate) ids.add("general.autoUpdate");
  if (!capabilities.defaultBrowser) ids.add("general.defaultBrowser");
  if (!capabilities.launchAtLogin) ids.add("general.openAtLogin");
  if (!capabilities.videoUpscaling) ids.add("tabs.videoUpscaling");
  if (!capabilities.cliControl) for (const id of ["advanced.ardiaCommand", "advanced.compactCliPill"]) ids.add(id);
  if (!capabilities.peekOtherSites) ids.add("tabs.peekLinksToOtherSites");
  if (!capabilities.popupsOpenAsTabs) ids.add("tabs.popupsOpenAsTabs");
  if (!capabilities.littleArdiaNewTabLinks) ids.add("tabs.littleArdiaOpensNewTabLinks");
  if (!capabilities.linksFromOtherApps) for (const id of ["tabs.openLinksInLittleArdia", "tabs.appLinksFirst"]) ids.add(id);
  if (!capabilities.webkit) for (const id of WEB_ENGINE_SETTINGS) if (settingIds.includes(id)) ids.add(id);
  return ids;
}

export const unavailableCommands = (capabilities: LinuxCapabilities): Set<string> =>
  new Set([
    "copyLastFreeze",
    ...(capabilities.externalLinks ? [] : ["emailPageLocation"]),
    ...(capabilities.linksFromOtherApps ? [] : ["toggleOpenLinksInLittleArdia"]),
    ...(capabilities.webkit ? [] : ["togglePageEngine", "toggleJavaScriptFromAppleEvents"]),
    ...(capabilities.fullScreen ? [] : [FULL_SCREEN_ITEM]),
    ...(capabilities.hiddenElements ? [] : ["hideElement", "showHiddenElements"]),
  ]);


export const unavailableError = (feature: string) => Object.assign(new Error(`${feature} is unavailable on Linux`), { code: "ERR_UNAVAILABLE" });
