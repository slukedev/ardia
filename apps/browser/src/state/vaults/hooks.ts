import { useVaultCodes } from "./codes";
import { useMemo } from "react";
import { rowsOfMenu, useVaultMenus, type VaultMenu } from "./menu";
import { liveItemOf } from "./menuModel";
import type { VaultItem } from "./types";
import { useVaultSaveOffers } from "./saveOffer";
import { useVaults } from "./store";
import { useBrowser } from "../browser/store";
import { useVaultBiometrics } from "./biometrics";
import { EVERY_VAULT, syncStatusOf, useVaultSync } from "./sync";

export function useVaultSyncStatus(id: string) {
  const native = useVaults((s) => !!s.providers.find((p) => p.id === id)?.syncing);
  const pressed = useVaultSync((s) => s[id]);
  return syncStatusOf(native, pressed);
}
export const useVaultSyncing = (id: string) => useVaultSyncStatus(id) === "syncing";
export function useAnyVaultSyncing() {
  const native = useVaults((s) => s.providers.some((p) => !!p.syncing));
  const pressed = useVaultSync((s) => Object.values(s).includes("syncing"));
  return native || pressed;
}
export function useEveryVaultSyncStatus() {
  const any = useAnyVaultSyncing();
  const pressed = useVaultSync((s) => s[EVERY_VAULT]);
  return syncStatusOf(any, pressed);
}

export const useVaultProviders = () => useVaults((s) => s.providers);
export const useVaultProvider = (id: string) => useVaults((s) => s.providers.find((p) => p.id === id));
export const useVaultTouchID = () => {
  const available = useVaultBiometrics((s) => s.available);
  const asks = useBrowser((s) => s.settings.vaultAskBeforeFilling);
  return available && asks;
};
export const useVaultMenuGlass = () => useBrowser((s) => s.settings.vaultMenuGlass);
export function useVaultLogins() {
  const items = useVaults((s) => s.items);
  const providers = useVaults((s) => s.providers);
  return useMemo(() => {
    const unlocked = new Set(providers.filter((p) => p.state === "unlocked").map((p) => p.id));
    return Object.values(items)
      .flat()
      .filter((i) => unlocked.has(i.provider));
  }, [items, providers]);
}
export const useLiveVaultItem = (item: VaultItem) => useVaults((s) => liveItemOf(s.items[item.provider] ?? [], item));
export const useLockedVaults = () => {
  const providers = useVaults((s) => s.providers);
  return useMemo(() => providers.filter((p) => p.state === "locked"), [providers]);
};
export const useVaultUnlocking = (id: string) => useVaults((s) => s.unlocking.includes(id));
export const useVaultsLoaded = () => useVaults((s) => s.loaded);
export const useVaultCode = (key: string) => useVaultCodes((s) => s[key]);
export const useVaultMenu = (tabId: string) => useVaultMenus((s) => s.menus[tabId] ?? null);
export const useVaultSaveOffer = (tabId: string) => useVaultSaveOffers((s) => s[tabId] ?? null);

export function useVaultMenuRows(menu: VaultMenu) {
  const revision = useVaults((s) => s.revision);
  return useMemo(() => rowsOfMenu(menu), [menu, revision]);
}
