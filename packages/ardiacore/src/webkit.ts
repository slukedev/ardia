import type { SiteSettingType } from "./siteSettings";

export type PageEngine = "chromium" | "webkit";

export type PageCookie = {
  name: string;
  value: string;
  domain: string;
  path: string;
  expires: number;
  session: boolean;
  httpOnly: boolean;
  secure: boolean;
  sameSite?: "Strict" | "Lax" | "None";
  partitionKey?: unknown;
  partitionKeyOpaque?: boolean;
};

export type PasskeyAccessStatus = "entitlementRequired" | "deviceNotConfigured" | "notDetermined" | "authorized" | "denied";
export type PasskeyAccess = { entitled: boolean; status: PasskeyAccessStatus };

export const NO_PASSKEY_ACCESS: PasskeyAccess = { entitled: false, status: "entitlementRequired" };

export const WEBKIT_SITE_SETTINGS: readonly SiteSettingType[] = ["camera", "microphone", "location", "notifications"];

export type WebKitExtension = {
  id: string;
  path: string | null;
  version: string;
  name: string;
  sites: string[];
  allSites: boolean;
  incognito: boolean;
};

export type WebKitExtensionsSync = { available: boolean; loaded: string[]; failed: string[] };

export type WebKitCount =
  | "autofillFill"
  | "autofillSaveOffer"
  | "autofillSave"
  | "notification"
  | "autofillUpdateOffer"
  | "autofillUpdate"
  | "autofillNever"
  | "cookieReplaced"
  | "workerNotification"
  | "workerShownNotification"
  | "workerClick"
  | "translation"
  | "extensionAction"
  | "shimDownloads"
  | "shimHistory"
  | "shimBookmarks"
  | "shimTabGroups"
  | "shimSidePanel"
  | "nativeHostLaunch"
  | "nativeHostFailure"
  | "privateExtensionLoaded";

export type WebKitExtensionApi = "downloads" | "history" | "bookmarks" | "tabGroups" | "sidePanel";

export type WebKitExtensionCall = {
  id: string;
  profile: string;
  base: string;
  private: boolean;
  extensionId: string;
  api: WebKitExtensionApi;
  method: string;
  args: unknown[];
  tabKeys: (string | null)[];
  windows: string[][];
};

export type WebKitExtensionReply = { result: unknown } | { error: string };

export type WebKitExtensionListeners = { profile: string; base: string; private: boolean; apis: WebKitExtensionApi[] };

export type WebKitExtensionEvent = { api: WebKitExtensionApi; event: string; args: unknown[] };
