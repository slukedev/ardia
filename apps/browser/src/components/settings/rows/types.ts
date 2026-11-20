import type { Settings } from "../../../state/settings/settings";

export type SettingsEnv = { top: boolean; glass?: boolean; syncOn?: boolean; calendarAccess?: boolean; officialPlugins?: readonly string[] };
export type SettingRow = { title: string; description?: string; explained?: boolean; keywords?: string[]; shown?: (settings: Settings, env: SettingsEnv) => boolean; needs?: string };
export type SettingSection = { section: string; rows: Record<string, SettingRow> };

export const APP = "Ardia";

export const WEBKIT_LIMITS_KEYWORDS = ["webkit limitations", "limitations", "not supported", "unsupported", "passkeys", "security keys", "picture in picture", "client hints", "midi", "casting", "chromecast", "chrome.debugger", "webrequest", "removeparam", "about engines", "how automatic works"];

export const ENGINE_MODE_ROW = {
  title: "Engine",
  keywords: ["engine mode", "only", "just", "chromium only", "webkit only", "safari", "automatic", "always"],
} satisfies SettingRow;
