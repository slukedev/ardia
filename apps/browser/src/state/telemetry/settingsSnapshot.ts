import { customNewTabUrl, SETTING_SPECS, type Settings, type SettingSpec } from "../settings/settings";
import { commandBarStartFlags } from "../omnibox/commandBarStart";
import { WIDEVINE_COMPONENT_ID, type EngineComponent } from "../../platform/app";
import { lookUse, type LookBlocks } from "../../lib/themeLook";
import { type PresetLookFields } from "../../lib/profileLook";
import { editedPresetCount } from "../../lib/presetLook";
import { currentThemeLook } from "../config/basePalette";
import type { BrowserWindow } from "../browser/types";
import { shownSidebarWidth } from "../../lib/windowLayout";
import { systemIncreaseContrast } from "../app/systemContrast";
import { isNavigationOrFunctionKey, storedShortcut } from "../commands/shortcuts";
import { isMouseKey } from "../commands/mouseButtons";
import { currentInterfaceScale } from "../settings/interfaceScale";
import { INTERFACE_SCALE, interfaceScalePercent, rootLength, windowLength } from "../../lib/interfaceScale";
import { drawnWindowCornerRadius } from "../../platform/windows";

export const SETTINGS_SNAPSHOT_EVENT = "settings_snapshot";

const encode = (value: unknown): string | null => {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number" && Number.isFinite(value)) return String(Math.round(value * 1000) / 1000);
  return null;
};

const choiceOf = (spec: SettingSpec<unknown>, value: unknown): string | null => (spec.values?.includes(value) && typeof value === "string" ? value : null);

function measured(spec: SettingSpec<unknown>, value: unknown): string | null {
  if (spec.values) return choiceOf(spec, value);
  if (typeof spec.default === "boolean") return typeof value === "boolean" ? encode(value) : null;
  if (typeof spec.default === "number" || spec.default === null) return value === null || typeof value === "number" ? encode(value) : null;
  return null;
}

function customShortcutCounts(overrides: Settings["shortcuts"]): Record<string, string> {
  const keys = Object.values(overrides).filter((stored) => stored[0]).map((stored) => storedShortcut(stored).key);
  const optionOnly = Object.values(overrides).filter((stored) => stored[0]).map((stored) => storedShortcut(stored).modifiers).filter((mods) => mods.includes("option") && !mods.includes("command") && !mods.includes("control"));
  return { custom_shortcuts: String(keys.length), custom_shortcuts_navigation_keys: String(keys.filter(isNavigationOrFunctionKey).length), custom_shortcuts_option_only: String(optionOnly.length) };
}

export function settingsSnapshot(settings: Settings): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, spec] of Object.entries(SETTING_SPECS) as [keyof Settings, SettingSpec<unknown>][]) {
    const value = measured(spec, settings[key]);
    const fallback = measured(spec, spec.default);
    if (value === null || fallback === null) continue;
    out[`setting_${key}`] = value;
    out[`default_${key}`] = fallback;
  }
  return {
    ...out,
    ...commandBarStartFlags(settings.commandBarStart),
    ...customShortcutCounts(settings.shortcuts),
    custom_mouse_shortcuts: String(Object.values(settings.mouseShortcuts ?? {}).filter((stored) => isMouseKey(stored[0] ?? "")).length),
    setting_interfaceScale: String(interfaceScalePercent(currentInterfaceScale())),
    default_interfaceScale: String(interfaceScalePercent(INTERFACE_SCALE.default)),
    system_increase_contrast: encode(systemIncreaseContrast())!,
    window_corner_radius: encode(windowLength(drawnWindowCornerRadius(), currentInterfaceScale())) ?? "unknown",
    unread_hidden_sites: String(Array.isArray(settings.unreadHiddenSites) ? settings.unreadHiddenSites.length : 0),
    custom_new_tab_url: customNewTabUrl({ newTabOpens: "page", minimalismMode: false, newTabUrl: typeof settings.newTabUrl === "string" ? settings.newTabUrl : "" }) ? "true" : "false",
  };
}

export const appIconSetting = (icon: string | null): Record<string, string> =>
  icon && /^[a-z]{1,16}$/.test(icon) ? { setting_app_icon: icon, default_app_icon: "default" } : {};

export function customColorProfiles(profiles: Record<string, PresetLookFields>, defaultProfileId?: string): Record<string, string> {
  const all = Object.values(profiles);
  const main = defaultProfileId ? profiles[defaultProfileId] : undefined;
  return {
    custom_color_profiles: String(all.filter((profile) => !!profile.theme).length),
    edited_presets: String(all.reduce((sum, profile) => sum + editedPresetCount(profile), 0)),
    ...(main ? { default_profile_color_edited: main.theme ? "true" : "false" } : {}),
  };
}

const NOT_INSTALLED = "0.0.0.0";

const widevineInstalled = (components: EngineComponent[]) => components.some((c) => c.id === WIDEVINE_COMPONENT_ID && c.version !== NOT_INSTALLED);

export const widevineSetting = (components: EngineComponent[] | null): Record<string, string> =>
  components ? { setting_widevine_installed: widevineInstalled(components) ? "true" : "false", default_widevine_installed: "false" } : {};

export const openTabSyncProfiles = (profiles: Record<string, { syncTabs?: true }>): Record<string, string> => ({
  sync_open_tabs_profiles: String(Object.values(profiles).filter((profile) => !!profile.syncTabs).length),
});

const FORMER_MIN_WINDOW_WIDTH = 720;

export function narrowWindows(windows: Record<string, Pick<BrowserWindow, "kind" | "frame" | "fullScreen">>, sidebarWidth: number, scale = currentInterfaceScale()): Record<string, string> {
  const widths = Object.values(windows).flatMap((w) => (w.kind !== "small" && !w.fullScreen && w.frame ? [rootLength(w.frame[2], scale)] : []));
  return {
    narrow_windows: String(widths.filter((width) => width < FORMER_MIN_WINDOW_WIDTH).length),
    sidebar_narrowed_windows: String(widths.filter((width) => shownSidebarWidth(sidebarWidth, width) < sidebarWidth).length),
  };
}

export function themeFileSnapshot(theme: string | null, blocks: LookBlocks | null): Record<string, string> {
  const use = lookUse(blocks);
  const flag = (on: boolean) => (on ? "true" : "false");
  return {
    theme_file: flag(theme !== null),
    theme_type: flag(use.type),
    theme_metrics: flag(use.metrics),
    theme_layout: flag(use.layout),
    theme_icons: flag(use.icons),
    theme_hidden_parts: String(use.hidden),
    theme_moved_parts: String(use.moved),
    theme_icon_overrides: String(use.iconOverrides),
  };
}

export function currentThemeFileSnapshot(): Record<string, string> {
  const { theme, blocks } = currentThemeLook();
  return themeFileSnapshot(theme, blocks);
}
