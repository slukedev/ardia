import { decodeReply } from "./engine/call";
import { nativeModule } from "./nativeModules";

export type VaultProviderId = "1password" | "bitwarden" | "protonpass" | "google" | (string & {});
export type VaultState = "notInstalled" | "signedOut" | "locked" | "unlocked" | "unavailable";
export type VaultSecretField = "username" | "password" | "totp";
export type VaultCapabilities = { totp: boolean; save: boolean; selfHosted: boolean; masterPassword: boolean; touchID: boolean };
export type VaultSetupKind = "desktopIntegration" | "browserSignIn" | "credentials" | "chrome";

export type VaultProviderState = {
  id: VaultProviderId;
  name: string;
  state: VaultState;
  account?: string;
  server?: string;
  cliPath?: string;
  cliVersion?: string;
  message?: string;
  settingsURL?: string;
  capabilities: VaultCapabilities;
  install: { command: string; url: string };
  setup?: { kind: VaultSetupKind; appURL?: string };
  touchUnlock?: boolean;
  refreshedAt?: number;
  syncAgainAt?: number;
  hold?: string;
  syncing?: boolean;
};

export type VaultItem = {
  provider: VaultProviderId;
  id: string;
  title: string;
  username: string;
  urls: string[];
  hasTotp?: boolean;
  vault?: string;
  favorite?: boolean;
  updatedAt?: number;
  pending?: boolean;
};

export type VaultSignInMethod = { id: string; name: string };

export type VaultSignInResult = {
  ok: boolean;
  state: VaultProviderState;
  needs?: "code" | "password" | "email" | "approval";
  methods?: VaultSignInMethod[];
  error?: string;
  approvalURL?: string;
};

export type VaultSignInFields = {
  email?: string;
  password?: string;
  code?: string;
  method?: string;
  server?: string;
  clientId?: string;
  clientSecret?: string;
  account?: string;
};

export type VaultTotp = { code: string; period: number; expiresAt: number };

export type VaultChromeProfile = { directory: string; name: string; email: string | null; selected: boolean };

export type VaultGoogleImportState = "confirm" | "saved" | "failed";
export type VaultGoogleExport = { provider: VaultProviderId; id: string; state: VaultGoogleImportState; trigger: "unlock" | "schedule" | "person" | "personAnyway" | "use" | "afterSave"; code?: string; message?: string };
export type VaultGoogleImport = { provider: VaultProviderId; id: string; state: VaultGoogleImportState; host: string; code?: string; message?: string };
export type VaultGoogleAccount = { email: string | null; hasPassword: boolean };
export type VaultGoogleSignIn = "signedIn" | "signIn" | "insecureBrowser" | "network" | "unavailable";

const Vaults = nativeModule("ArdiaVaults");

export const signInToVault = (provider: VaultProviderId, fields: VaultSignInFields) =>
  decodeReply<VaultSignInResult>(Vaults.signIn(provider, JSON.stringify(fields)));
export const unlockVault = (provider: VaultProviderId, password: string | null) =>
  decodeReply<VaultSignInResult>(Vaults.unlock(provider, password));
export const saveGooglePassword = (email: string, password: string) => decodeReply<{ ok: boolean; error: string }>(Vaults.saveGooglePassword(email, password));
