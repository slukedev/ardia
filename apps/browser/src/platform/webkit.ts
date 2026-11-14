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
} from "@ardia/ardiacore";

export { NO_PASSKEY_ACCESS };
export type { PasskeyAccess, PasskeyAccessStatus, PageCookie, WebKitCount, WebKitExtension, WebKitExtensionsSync };

export const endWebKitPrivateSession = (session: string) => call("webKit.endPrivateSession", { session });
export const webKitCookieStoreKey = (profile: string) => call("webKit.cookieStoreKey", { profile });
export const importWebKitCookies = (profile: string, storeKey: string, cookies: PageCookie[]) =>
  call("webKit.importCookies", { profile, storeKey, cookies });
export const exportWebKitCookies = (profile: string, urls: string[]) => call("webKit.exportCookies", { profile, urls });
export const setWebKitZoom = (profile: string, host: string, zoom: number) => call("webKit.setZoom", { profile, host, zoom });
export const syncWebKitExtensions = (profile: string, extensions: WebKitExtension[]) => call("webKit.syncExtensions", { profile, extensions });
export const onWebKitCount = (listener: (e: { name: WebKitCount }) => void) => on("webKit.counted", listener);
export const getPasskeyAccess = () => call("webKit.passkeyAccess");
export const requestPasskeyAccess = () => call("webKit.requestPasskeyAccess");
