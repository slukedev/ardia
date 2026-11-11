import { AppState } from "react-native";
import { create } from "zustand";
import { checkGoogleSignIn, chromeProfiles, onGoogleExport, onGoogleSignIn, forgetGooglePassword, googleAccount, isChromeVault, revealGooglePage, storeGooglePassword, type ChromeProfile, type VaultGoogleAccount, type VaultGoogleSignIn, type VaultProviderState } from "../../platform/vaults";
import { openSettings } from "../settings/settingsWindows";
import { configureProvider, refreshProvider } from "./actions";
import { currentVaultProviders, loadAllVaultItems, loadVaultItems, vaultProviderOf } from "./store";

export type { ChromeProfile };
export { isChromeVault };

export const useChromeProfiles = create<Record<string, ChromeProfile[]>>()(() => ({}));

export const setChromeProfiles = (provider: string, profiles: ChromeProfile[]) => useChromeProfiles.setState({ [provider]: profiles });

const DAY_MS = 86_400_000;

const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
const dayFormat = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });

export function updatedLine(refreshedAt: number | undefined, now = Date.now()): string | undefined {
  if (!refreshedAt || !Number.isFinite(refreshedAt)) return undefined;
  const age = now - refreshedAt;
  if (age < 60_000) return "Updated just now";
  const then = new Date(refreshedAt);
  const startOfToday = new Date(now).setHours(0, 0, 0, 0);
  if (refreshedAt >= startOfToday) return `Updated at ${timeFormat.format(then)}`;
  if (refreshedAt >= startOfToday - DAY_MS) return "Updated yesterday";
  return `Updated ${dayFormat.format(then)}`;
}

export const clockTime = (at: number) => timeFormat.format(new Date(at));

export const GOOGLE_HOLD_LINE = "Google needs you to confirm";
export const GOOGLE_FAILED_LINE = "Couldn't update";

export const googleUpdateFailed = (p: Pick<VaultProviderState, "state" | "message" | "hold">) => p.state === "unlocked" && !p.hold && !!p.message;

export function chromeStatusLine(p: Pick<VaultProviderState, "state" | "account" | "message" | "refreshedAt" | "hold">, now = Date.now()): string | undefined {
  switch (p.state) {
    case "notInstalled":
    case "signedOut":
      return "Not connected";
    case "locked":
      return p.message || [p.account, "Locked"].filter(Boolean).join(" · ");
    case "unlocked":
      return [p.account, p.hold ? GOOGLE_HOLD_LINE : googleUpdateFailed(p) ? GOOGLE_FAILED_LINE : updatedLine(p.refreshedAt, now)].filter(Boolean).join(" · ") || undefined;
    default:
      return p.message || "Not available";
  }
}

export type ChromeProfileOption = { value: string; title: string };

export function chromeProfileOptions(profiles: readonly ChromeProfile[]): ChromeProfileOption[] {
  const named = new Map<string, number>();
  for (const p of profiles) named.set(p.name, (named.get(p.name) ?? 0) + 1);
  return profiles.map((p) => ({ value: p.directory, title: (named.get(p.name) ?? 0) > 1 && p.email ? `${p.name} (${p.email})` : p.name }));
}

export function chosenChromeProfile(profiles: readonly ChromeProfile[], p: Pick<VaultProviderState, "server" | "account">): string | null {
  const match = profiles.find((x) => x.selected) ?? profiles.find((x) => x.directory === p.server) ?? profiles.find((x) => x.name === p.server) ?? profiles.find((x) => !!p.account && x.email === p.account);
  return match?.directory ?? null;
}

export async function loadChromeProfiles(provider: string) {
  if (!vaultProviderOf(provider)) return;
  const profiles = await chromeProfiles().catch(() => null);
  if (profiles) setChromeProfiles(provider, profiles);
}

export async function chooseChromeProfile(provider: string, directory: string): Promise<string> {
  const state = await configureProvider(provider, directory);
  if (!state) return "Couldn't switch Chrome profiles. Try again.";
  if (state.message) return state.message;
  void loadVaultItems(provider, true);
  void loadChromeProfiles(provider);
  return "";
}

const waitingOnChrome = (p: VaultProviderState) => isChromeVault(p) && (p.state === "notInstalled" || p.state === "signedOut");

let watching = false;

export function startChromeVaultWatch() {
  if (watching) return;
  watching = true;
  onGoogleExport((event) => {
    if (event.state === "confirm" && event.trigger === "person") void revealGooglePage(event.id).catch(() => false);
  });
  AppState.addEventListener("change", (state) => {
    if (state !== "active") return;
    for (const p of currentVaultProviders()) if (waitingOnChrome(p)) void refreshProvider(p.id);
    void loadAllVaultItems();
  });
}

export const useGoogleAccount = create<VaultGoogleAccount & { loaded: boolean; sheetRequest: number }>()(() => ({ email: null, hasPassword: false, loaded: false, sheetRequest: 0 }));

export async function loadGoogleAccount() {
  const account = await googleAccount().catch(() => null);
  if (account) useGoogleAccount.setState({ ...account, loaded: true });
  return account;
}

export async function forgetGoogleAccountPassword() {
  const account = await forgetGooglePassword().catch(() => null);
  if (account) useGoogleAccount.setState({ ...account, loaded: true });
}

export async function saveGoogleAccountPassword(email: string, password: string): Promise<string> {
  const trimmed = email.trim();
  if (!/^[^\s@]+@[^\s@]+$/.test(trimmed)) return "Enter the email of your Google Account.";
  if (!password) return "Enter your Google password.";
  const result = await storeGooglePassword(trimmed, password).catch(() => null);
  if (!result?.ok) return result?.error || "Ardia couldn't keep your Google password. Try again.";
  await loadGoogleAccount();
  return "";
}

export function requestGooglePasswordSheet() {
  useGoogleAccount.setState((s) => ({ sheetRequest: s.sheetRequest + 1 }));
  openSettings("passwords");
}

export const GOOGLE_SIGN_IN_TEXT: Record<VaultGoogleSignIn, string> = {
  signedIn: "Signed in to Google in Ardia",
  signIn: "Not signed in to Google in Ardia",
  insecureBrowser: "Google says this browser may not be secure",
  network: "Ardia couldn't reach Google",
  unavailable: "Ardia isn't ready yet",
};

export const checkGoogleSignInState = () => checkGoogleSignIn().catch((): VaultGoogleSignIn => "unavailable");
export type GoogleSignInState = VaultGoogleSignIn;
export const watchGoogleSignIn = (listener: () => void) => onGoogleSignIn(() => listener());
export const showGoogleSignIn = () => void revealGooglePage().catch(() => false);
