import {
  call,
  on,
  NO_PASSKEY_ACCESS,
  type PageCookie,
  type PasskeyAccess,
  type PasskeyAccessStatus,
  type WebKitCount,
  type WebKitExtension,
  type WebKitExtensionsSync,
  type WebKitExtensionApi,
  type WebKitExtensionCall,
  type WebKitExtensionEvent,
  type WebKitExtensionListeners,
  type WebKitExtensionReply,
} from "@ardia/ardiacore";

export { NO_PASSKEY_ACCESS };
export type { PasskeyAccess, PasskeyAccessStatus, PageCookie, WebKitCount, WebKitExtension, WebKitExtensionsSync };
export type { WebKitExtensionApi, WebKitExtensionCall, WebKitExtensionEvent, WebKitExtensionListeners, WebKitExtensionReply };

export const endWebKitPrivateSession = (session: string) => call("webKit.endPrivateSession", { session });
export const webKitCookieStoreKey = (profile: string) => call("webKit.cookieStoreKey", { profile });
export const importWebKitCookies = (profile: string, storeKey: string, cookies: PageCookie[]) =>
  call("webKit.importCookies", { profile, storeKey, cookies });
export const exportWebKitCookies = (profile: string, urls: string[]) => call("webKit.exportCookies", { profile, urls });
export const setWebKitZoom = (profile: string, host: string, zoom: number) => call("webKit.setZoom", { profile, host, zoom });
export const syncWebKitExtensions = (profile: string, extensions: WebKitExtension[]) => call("webKit.syncExtensions", { profile, extensions });
export const onWebKitCount = (listener: (e: { name: WebKitCount }) => void) => on("webKit.counted", listener);
export const onWebKitExtensionCall = (listener: (e: WebKitExtensionCall) => void) => on("webKit.extensionCall", listener);
export const onWebKitExtensionListeners = (listener: (e: WebKitExtensionListeners) => void) => on("webKit.extensionListeners", listener);
export const onWebKitExtensionsWanted = (listener: (e: { profile: string }) => void) => on("webKit.extensionsWanted", listener);
export const replyToWebKitExtension = (id: string, reply: WebKitExtensionReply) => call("webKit.extensionReply", { id, reply });
export const sendWebKitExtensionEvent = (profile: string, event: WebKitExtensionEvent) => call("webKit.extensionEvent", { profile, event });
export const getPasskeyAccess = () => call("webKit.passkeyAccess");
export const requestPasskeyAccess = () => call("webKit.requestPasskeyAccess");
