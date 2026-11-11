import { call, on, saveGooglePassword, signInToVault, type VaultGoogleAccount, type VaultGoogleExport, type VaultGoogleImport, type VaultGoogleSignIn, type VaultSaveResult, unlockVault as unlockNativeVault, type VaultItem, type VaultProviderState, type VaultSecretField, type VaultSignInFields, type VaultSignInResult, type VaultTotp } from "@ardia/ardiacore";

export type { VaultItem, VaultProviderState, VaultSignInFields, VaultSignInResult, VaultTotp };

export type VaultCopyField = VaultSecretField;

export const vaultProviders = () => call("vaults.providers");
export const refreshVault = (provider: string, anyway = false) => call("vaults.refresh", anyway ? { provider, anyway } : { provider });
export const vaultItems = (provider?: string) => call("vaults.items", provider ? { provider } : {});
export const lockVault = (provider: string) => call("vaults.lock", { provider });
export const signOutVault = (provider: string) => call("vaults.signOut", { provider });
export const configureVault = (provider: string, server: string | null) => call("vaults.configure", { provider, server });
export const copyFromVault = (provider: string, id: string, field: VaultCopyField) => call("vaults.copy", { provider, id, field });
export const vaultTotp = (provider: string, id: string) => call("vaults.totp", { provider, id });
export const cancelVaultSignIn = (provider: string) => call("vaults.cancelSignIn", { provider });
export const setVaultOptions = (idleLockMinutes: number, touchID: boolean, askBeforeFilling: boolean, loadPasswordsWhenUsed: boolean, syncIntervalSeconds: number | null) =>
  call("vaults.setOptions", { idleLockMinutes, touchID, askBeforeFilling, loadPasswordsWhenUsed, syncIntervalSeconds });
export const vaultBiometrics = () => call("vaults.biometrics", {}).then((r) => r.available);

export const signInVault = (provider: string, fields: VaultSignInFields) => signInToVault(provider, fields);
export const unlockVault = (provider: string, password: string | null) => unlockNativeVault(provider, password);

export const onVaultChanged = (listener: (state: VaultProviderState) => void) => on("vaults.changed", ({ provider }) => listener(provider));
export const onVaultTouchID = (listener: () => void) => on("vaults.touchID", () => listener());
export const onVaultItemsChanged = (listener: (provider: string) => void) => on("vaults.itemsChanged", ({ provider }) => listener(provider));

export type { VaultField, VaultFieldKind, VaultFieldRect, VaultFillError, VaultFillField, VaultKeyPress, VaultSubmission } from "@ardia/ardiacore";

export type ChromeProfile = { directory: string; name: string; email: string | null; selected?: boolean };
export type { VaultGoogleAccount, VaultGoogleExport, VaultGoogleImport, VaultGoogleSignIn };
export type VaultSaveOutcome = { kind: "saved"; importId?: string } | { kind: "confirm"; importId: string; error: string } | { kind: "failed"; error: string; action?: "updatePassword" };

export const isChromeVault = (p: Pick<VaultProviderState, "setup">) => p.setup?.kind === "chrome";

export const chromeProfiles = () => call("vaults.googleProfiles", {});
export const googleAccount = () => call("vaults.googleAccount", {});
export const forgetGooglePassword = () => call("vaults.forgetGooglePassword", {});
export const checkGoogleSignIn = () => call("vaults.googleSignIn", {}).then((r) => r.state);
export const revealGooglePage = (id?: string) => call("vaults.googleReveal", id ? { id } : {}).then((r) => r.revealed);
export const storeGooglePassword = (email: string, password: string) => saveGooglePassword(email, password);
export const onGoogleExport = (listener: (event: VaultGoogleExport) => void) => on("vaults.googleExport", listener);
export const onGoogleImport = (listener: (event: VaultGoogleImport) => void) => on("vaults.googleImport", listener);
export const onGoogleSignIn = (listener: (signedIn: boolean) => void) => on("vaults.googleSignIn", ({ signedIn }) => listener(signedIn));

const usable = (text: string | undefined) => (text && text !== "failed" ? text : "");

export function saveOutcome(reply: VaultSaveResult | null): VaultSaveOutcome {
  if (reply?.saved) return reply.importId ? { kind: "saved", importId: reply.importId } : { kind: "saved" };
  if (reply?.code === "confirm" && reply.importId) return { kind: "confirm", importId: reply.importId, error: usable(reply.error) };
  return { kind: "failed", error: usable(reply?.error), ...(reply?.action === "updatePassword" ? { action: "updatePassword" as const } : {}) };
}
