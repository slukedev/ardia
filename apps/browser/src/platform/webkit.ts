import { call, on, NO_PASSKEY_ACCESS, type EngineEvents, type PageCookie, type PasskeyAccess, type PasskeyAccessStatus, type WebKitCount } from "@ardia/ardiacore";

export { NO_PASSKEY_ACCESS };
export type { PasskeyAccess, PasskeyAccessStatus, PageCookie, WebKitCount };

export const endWebKitPrivateSession = (session: string) => call("webKit.endPrivateSession", { session });
export const webKitCookieStoreKey = (profile: string) => call("webKit.cookieStoreKey", { profile });
export const importWebKitCookies = (profile: string, storeKey: string, cookies: PageCookie[]) =>
  call("webKit.importCookies", { profile, storeKey, cookies });
export const setWebKitFraudWarnings = (enabled: boolean) => call("webKit.setFraudWarnings", { enabled });
export const setWebKitZoom = (profile: string, host: string, zoom: number) => call("webKit.setZoom", { profile, host, zoom });
export const onWebKitCount = (listener: (e: { name: WebKitCount; epoch?: string }) => void) => on("webKit.counted", listener);
export const webKitNotificationAction = (id: string, action: "click" | "close") => call("webKit.notificationAction", { id, action });
export const onWebKitNotification = (listener: (e: EngineEvents["webKit.notification"]) => void) => on("webKit.notification", listener);
export const onWebKitNotificationClose = (listener: (e: { id: string }) => void) => on("webKit.notificationClose", listener);
export const onWebKitOpenWindow = (listener: (e: EngineEvents["webKit.openWindow"]) => void) => on("webKit.openWindow", listener);
export const getPasskeyAccess = () => call("webKit.passkeyAccess");
export const requestPasskeyAccess = () => call("webKit.requestPasskeyAccess");
