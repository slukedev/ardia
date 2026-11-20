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

export type StorageItems = [string, string][];

export type PasskeyAccessStatus = "entitlementRequired" | "deviceNotConfigured" | "notDetermined" | "authorized" | "denied";
export type PasskeyAccess = { entitled: boolean; status: PasskeyAccessStatus };

export const NO_PASSKEY_ACCESS: PasskeyAccess = { entitled: false, status: "entitlementRequired" };

export const WEBKIT_SITE_SETTINGS: readonly SiteSettingType[] = ["camera", "microphone", "location", "notifications", "popups", "javascript", "images", "cookies", "autoplay", "clipboard"];

export type WebKitCount =
  | "autofillAddressFill"
  | "autofillCardFill"
  | "autofillCardReauthRefused"
  | "autofillAddressSaveOffer"
  | "autofillAddressSave"
  | "autofillCardSaveOffer"
  | "autofillCardSave"
  | "autofillFill"
  | "autofillSaveOffer"
  | "autofillSave"
  | "notification"
  | "autofillUpdateOffer"
  | "autofillUpdate"
  | "autofillNever"
  | "passwordsLeftToManager"
  | "workerNotification"
  | "workerShownNotification"
  | "workerClick"
  | "translation"
  | "siteSettingApplied"
  | "uploadFiltered"
  | "screenShareRequest"
  | "screenShareAllowed"
  | "devTools"
  | "viewSource"
  | "savePage"
  | "savePageFailure"
  | "quarantineFailure"
  | "contextMenu"
  | "linkPeek"
  | "linkSplit"
  | "littleArdiaLink"
  | "scrollZoom"
  | "sampledTint"
  | "authPrompt"
  | "authPromptBlocked"
  | "dialogSuppressedWhileHidden"
  | "certificateInterstitial"
  | "certificateProceed"
  | "popupBlocked"
  | "blockedPopupOpened"
  | "errorPageRetry"
  | "appBadge"
  | "blockerCompileFailed"
  | "blockerCosmeticApplied"
  | "blockerStrictBlocked"
  | "blockerStrictProceed"
  | "blockerUserFilters"
  | "blockerUserFiltersFailed"
  | "blockerUserFiltersIsolated"
  | "discard"
  | "discardWake"
  | "downloadSkipped"
  | "fallbackFind"
  | "faviconChanged"
  | "fullscreen"
  | "historyRestored"
  | "linkDrop"
  | "nativeFind"
  | "pageMute"
  | "pageMuteFallback"
  | "selectionShown"
  | "soundRuleMuted"
  | "unresponsive"
  | "unresponsiveEnded"
  | "webAudioAudible";
