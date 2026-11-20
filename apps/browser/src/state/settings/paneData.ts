import { useBrowser } from "../browser/store";
import {
  engineInfo,
  appIcons,
  currentAppIcon,
  isDefaultBrowser,
  launchAtLoginStatus,
  setAppIcon,
  setAutomaticUpdateChecks,
  setAutomaticUpdateDownloads,
  setUpdateChannel,
  updaterState,
  type UpdateChannel,
  type UpdaterState,
} from "../../platform/app";
import { setAsDefaultBrowser } from "../app/appSettings";
import { getAutofillSettings, listAddresses, listCards, setAutofillSettings, type AutofillToggle, type SavedAddress, type SavedCard } from "../../platform/autofill";
import { getContentBlocker } from "../../platform/contentBlocker";
import { getDownloadSettings, setDownloadSettings, type DownloadSettings } from "../../platform/downloads";
import { getExternalAppAllowances, getPreloadPages, getSiteSettingsOrigins, getZoomLevels, setPreloadPages } from "../../platform/siteSettings";
import { getPasswordAutofill, setPasswordAutofill } from "../../platform/passwords";
import { orWarn } from "../../lib/fallback";
import { menuShortcuts } from "../../platform/commands";
import { setMenuBarShortcuts } from "../commands/commandShortcuts";
import { UNAVAILABLE_COMMANDS } from "../commands/commandCatalog";
import { currentSettings } from "../browser/current";
import { engineProfile } from "../browser/model";
import { currentSyncFolder, folderInfo } from "../sync/engine";
import { extensionsProfileId, refreshExtensions } from "../extensions/actions";
import { cached, load, loadAll, need, resource, store, useAllLoaded, type Needed } from "./resources";
import type { SettingsPane } from "./settingsWindows";
import { FOLLOW_EVERY_MS, FOLLOW_FOR_MS, FOLLOW_UPDATE_EVERY_MS, FOLLOW_UPDATE_FOR_MS, switchOutcome, updateUnderWay, updaterBusy } from "./updateStatus";
import { noteUpdateChannelSwitch } from "../telemetry/usage";
import { consentToken } from "../telemetry/client";
import { forgetPendingOfferToSave, passwordAutofill } from "../site/passwordManager";
import { notePreloadPagesTurned } from "../telemetry/preloadPagesCounts";
import { trackAutofillToggleKept } from "../telemetry/track";
import { askedValue, rememberAsked } from "./autofillAsked";

export { passwordAutofill };

export const APP_ICON_SIZE = 56;

export const loginItem = resource("loginItem", () => launchAtLoginStatus().catch(() => "notRegistered"));
export const defaultBrowser = resource("defaultBrowser", () => isDefaultBrowser().catch(() => false));
export const updater = resource("updater", (): Promise<UpdaterState> => updaterState().catch(() => ({ available: false })));
export const syncFolder = resource("syncFolder", (folder: string | null) => folderInfo(folder).catch(() => null));
export const appIconChoices = resource("appIcons", () =>
  Promise.all([appIcons(APP_ICON_SIZE), currentAppIcon()]).then(([icons, current]) => ({ icons, current }), () => ({ icons: [], current: null })),
);
export const contentBlocker = resource("contentBlocker", () => getContentBlocker().catch(() => null));
export const siteOrigins = resource("siteOrigins", (profile: string) => getSiteSettingsOrigins(profile).catch((): string[] => []));
export const appLinks = resource("appLinks", (profile: string) => getExternalAppAllowances(profile).catch(() => []));
export const zoomLevels = resource("zoomLevels", (profile: string) => getZoomLevels(profile).catch((): Record<string, number> => ({})));
export const preloadPages = resource("preloadPages", (profile: string) => getPreloadPages(profile).catch(() => false));
export const addresses = resource("addresses", (profile: string) => listAddresses(profile).catch(orWarn<SavedAddress[]>([])));
export const cards = resource("cards", (profile: string) => listCards(profile).catch(orWarn<SavedCard[]>([])));
export const autofillEnabled = resource("autofillEnabled", (profile: string) =>
  load(addresses, [profile]).then(() => getAutofillSettings(profile).catch(() => ({ addresses: true, cards: true }))),
);
export const autofillToggleAsked = resource("autofillToggleAsked", (profile: string, toggle: AutofillToggle) => Promise.resolve(askedValue(profile, toggle)));
export const downloadSettings = resource("downloadSettings", (profile: string) => getDownloadSettings(profile).catch(() => null));
export const extensionList = resource("extensions", (profile: string) => refreshExtensions(profile, consentToken()));
export const shortcutItems = resource("menuShortcuts", () =>
  menuShortcuts().then(
    (items) => (setMenuBarShortcuts(items), items.filter((item) => !UNAVAILABLE_COMMANDS.has(item.id))),
    () => [],
  ),
);
export const engineVersion = resource("engineInfo", () => engineInfo().catch(() => null));
const defaultProfile = () => engineProfile(useBrowser.getState(), currentSettings().defaultProfileId);

export function paneNeeds(pane: SettingsPane, profileId: string | null): Needed[] {
  const profile = profileId ? engineProfile(useBrowser.getState(), profileId) : defaultProfile();
  switch (pane) {
    case "general":
      return [need(loginItem), need(defaultBrowser), need(updater), need(downloadSettings, profile), need(contentBlocker), need(syncFolder, currentSyncFolder() ?? null), need(engineVersion)];
    case "profiles":
      return [
        need(downloadSettings, profile),
        need(preloadPages, profile),
        need(passwordAutofill, profile),
        need(autofillToggleAsked, profile, "passwords"),
        need(addresses, profile),
        need(cards, profile),
        need(autofillEnabled, profile),
        need(autofillToggleAsked, profile, "addresses"),
        need(autofillToggleAsked, profile, "cards"),
        need(extensionList, engineProfile(useBrowser.getState(), extensionsProfileId(profileId))),
      ];
    case "appearance":
      return [need(appIconChoices)];
    case "automations":
      return [need(appLinks, profile)];
    case "shortcuts":
      return [need(shortcutItems)];
    default:
      return [];
  }
}

export const usePaneLoaded = (pane: SettingsPane, profileId: string | null) => useAllLoaded(paneNeeds(pane, profileId));

export const preparePane = (pane: SettingsPane, profileId: string | null) => loadAll(paneNeeds(pane, profileId));

function noteAsked(profile: string, toggle: AutofillToggle, asked: boolean, now: boolean) {
  rememberAsked(profile, toggle, asked, now);
  store(autofillToggleAsked, [profile, toggle], asked);
  if (now !== asked) trackAutofillToggleKept(toggle);
}

const written = (write: Promise<unknown>) => write.then(() => true, orWarn(false));

export async function setPreloadPagesFor(profile: string, on: boolean) {
  const consent = consentToken();
  if (!(await written(setPreloadPages(profile, on)))) return;
  store(preloadPages, [profile], on);
  notePreloadPagesTurned(on, consent);
}

export async function setPasswordAutofillFor(profile: string, on: boolean) {
  if (!(await forgetPendingOfferToSave(profile, consentToken())) && !on) return;
  if (!(await written(setPasswordAutofill(on, profile)))) return;
  const now = await getPasswordAutofill(profile).catch(() => on);
  store(passwordAutofill, [profile], now);
  noteAsked(profile, "passwords", on, now);
}

export async function setAutofillFor(profile: string, kind: Exclude<AutofillToggle, "passwords">, on: boolean) {
  if (!(await written(setAutofillSettings({ [kind]: on }, profile)))) return;
  const enabled = cached(autofillEnabled, [profile]);
  const now = await getAutofillSettings(profile).catch(() => ({ ...(enabled ?? { addresses: true, cards: true }), [kind]: on }));
  store(autofillEnabled, [profile], now);
  noteAsked(profile, kind, on, now[kind]);
}

export const downloadFoldersDiffer = (profiles: string[]) =>
  Promise.all(profiles.map((p) => getDownloadSettings(p).catch(() => null))).then((all) => new Set(all.flatMap((d) => (d ? [d.folder] : []))).size > 1);

export const setDownloadsFor = (patch: Partial<Pick<DownloadSettings, "folder" | "askWhereToSave">>, profiles: string[]) =>
  Promise.all(profiles.map((p) => setDownloadSettings(patch, p).then((next) => store(downloadSettings, [p], next), orWarn(undefined))));

export function setUpdaterPrefs(patch: { automaticChecks?: boolean; automaticDownloads?: boolean; channel?: UpdateChannel }) {
  const state = cached(updater, []);
  if (state) store(updater, [], { ...state, ...patch });
  const reload = () => void load(updater, [], { fresh: true }).catch(() => {});
  const consent = consentToken();
  if (patch.automaticChecks !== undefined) void setAutomaticUpdateChecks(patch.automaticChecks).finally(reload);
  if (patch.automaticDownloads !== undefined) void setAutomaticUpdateDownloads(patch.automaticDownloads).finally(reload);
  if (patch.channel !== undefined) void setUpdateChannel(patch.channel).finally(() => followUpdater((s) => noteUpdateChannelSwitch(s.available ? switchOutcome(s.switchCheck) : null, consent)));
}

let following = 0;
let followingNow = false;

export function followUpdater(settled?: (state: UpdaterState) => void) {
  if (followingNow && !settled) return;
  const run = ++following;
  followingNow = true;
  const started = Date.now();
  const tick = (): Promise<void> =>
    load(updater, [], { fresh: true }).then((state) => {
      if (run !== following) return;
      const updating = updateUnderWay(state);
      if (updaterBusy(state) && Date.now() < started + (updating ? FOLLOW_UPDATE_FOR_MS : FOLLOW_FOR_MS)) return new Promise<void>((done) => setTimeout(done, updating ? FOLLOW_UPDATE_EVERY_MS : FOLLOW_EVERY_MS)).then(tick);
      followingNow = false;
      settled?.(state);
    });
  void tick().catch(() => run === following && (followingNow = false));
}

export function chooseAppIcon(id: string) {
  const choices = cached(appIconChoices, []);
  if (choices) store(appIconChoices, [], { ...choices, current: id });
  void setAppIcon(id);
}

export const makeDefaultBrowser = () => setAsDefaultBrowser().then((isDefault) => store(defaultBrowser, [], isDefault));
