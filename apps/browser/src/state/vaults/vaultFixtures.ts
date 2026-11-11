import type { ChromeProfile, VaultItem, VaultProviderState } from "../../platform/vaults";
import { setChromeProfiles } from "./google";
import { GOOGLE_CONFIRM_TEXT } from "./googleImport";
import { useVaultSaveOffers, type VaultOfferAction } from "./saveOffer";
import { setVaultUnlocking, stageVaults } from "./store";

type State = VaultProviderState["state"];

const caps = (save: boolean, masterPassword: boolean, touchID: boolean) => ({ totp: true, save, selfHosted: false, masterPassword, touchID });

const GOOGLE_EMAIL = "luke.appleseed@gmail.com";
const LONG_EMAIL = "lukas.appleseed-montgomery.personal.archive@googlemail.com";
const DENIED = "Ardia wasn't allowed to read Chrome's passwords. Click Unlock and choose Always Allow.";

export const CHROME_PROFILES: ChromeProfile[] = [
  { directory: "Default", name: "Personal", email: GOOGLE_EMAIL },
  { directory: "Profile 1", name: "Work", email: "luke@example.com" },
  { directory: "Profile 2", name: "Testing", email: null },
];

const google = (state: State, over: Partial<VaultProviderState> = {}): VaultProviderState => ({
  id: "google",
  name: "Google Password Manager",
  state,
  account: state === "locked" || state === "unlocked" ? GOOGLE_EMAIL : undefined,
  server: state === "locked" || state === "unlocked" ? "Default" : undefined,
  capabilities: caps(true, false, true),
  install: { command: "", url: "https://www.google.com/chrome/" },
  setup: { kind: "chrome" },
  ...over,
});

const OTHERS: VaultProviderState[] = [
  { id: "1password", name: "1Password", state: "locked", account: "luke@example.com", capabilities: caps(true, false, true), install: { command: "brew install --cask 1password-cli", url: "" }, setup: { kind: "desktopIntegration" } },
  { id: "bitwarden", name: "Bitwarden", state: "unlocked", account: "luke@example.com", server: "https://vault.bitwarden.com", capabilities: { ...caps(true, true, true), selfHosted: true }, install: { command: "brew install bitwarden-cli", url: "" }, setup: { kind: "credentials" } },
  { id: "protonpass", name: "Proton Pass", state: "signedOut", capabilities: caps(true, false, false), install: { command: "brew install protonpass/tap/pass-cli", url: "" }, setup: { kind: "browserSignIn" } },
];

const login = (provider: string, id: string, title: string, username: string, url: string, vault?: string): VaultItem => ({ provider, id, title, username, urls: [url], vault, hasTotp: false });

export const FIXTURE_ITEMS: VaultItem[] = [
  login("google", "g1", "github.com", "octo-luke", "https://github.com", "Google Account"),
  login("google", "g2", "github.com", "octo-luke", "https://github.com", "On This Mac"),
  login("google", "g3", "github.com", "luke-work", "https://github.com", "Google Account"),
  login("google", "g4", "news.ycombinator.com", "lukea", "https://news.ycombinator.com", "Google Account"),
  login("google", "g5", "figma.com", GOOGLE_EMAIL, "https://www.figma.com", "On This Mac"),
  login("bitwarden", "b1", "GitHub", "octo-bw", "https://github.com", "Personal"),
  login("bitwarden", "b2", "Linear", "luke@example.com", "https://linear.app", "Personal"),
];

export type GoogleFixture = "notInstalled" | "signedOut" | "locked" | "unlocking" | "denied" | "unlocked" | "unlocked3" | "longEmail" | "unavailable" | "syncing" | "pending" | "hold";

const PENDING_ITEM: VaultItem = { ...login("google", "pending.linear", "linear.app", "luke@example.com", "https://linear.app"), pending: true };

const GOOGLE_STATES: Record<GoogleFixture, () => VaultProviderState> = {
  notInstalled: () => google("notInstalled"),
  signedOut: () => google("signedOut"),
  locked: () => google("locked"),
  unlocking: () => google("locked"),
  denied: () => google("locked", { message: DENIED }),
  unlocked: () => google("unlocked"),
  unlocked3: () => google("unlocked"),
  longEmail: () => google("unlocked", { account: LONG_EMAIL }),
  unavailable: () => google("unavailable", { message: "Couldn't read Chrome's passwords." }),
  syncing: () => google("unlocked", { syncing: true, refreshedAt: Date.now() - 3 * 60_000 }),
  pending: () => google("unlocked", { syncing: true, refreshedAt: Date.now() }),
  hold: () => google("unlocked", { hold: "twoStep", refreshedAt: Date.now() - 3 * 60_000 }),
};

export function stageGoogleVault(fixture: GoogleFixture, { others = true }: { others?: boolean } = {}) {
  const state = GOOGLE_STATES[fixture]();
  const providers = others ? [...OTHERS, state] : [state];
  const unlocked = new Set(providers.filter((p) => p.state === "unlocked").map((p) => p.id));
  const items = fixture === "pending" ? [...FIXTURE_ITEMS, PENDING_ITEM] : FIXTURE_ITEMS;
  stageVaults(providers, items.filter((i) => unlocked.has(i.provider)));
  setVaultUnlocking("google", fixture === "unlocking");
  setChromeProfiles("google", fixture === "unlocked3" ? CHROME_PROFILES : fixture === "longEmail" ? [{ directory: "Default", name: "Personal", email: LONG_EMAIL }] : CHROME_PROFILES.slice(0, 1));
  return state;
}

export function stageGoogleSaveOffer(tabId: string, { action, targets = ["google"] }: { action?: VaultOfferAction; targets?: string[] } = {}) {
  useVaultSaveOffers.setState((s) => ({
    ...s,
    [tabId]: {
      seq: Date.now(),
      origin: "https://github.com",
      username: "octo-luke",
      targets,
      target: "google",
      busy: action === "confirm",
      error: action === "confirm" ? GOOGLE_CONFIRM_TEXT : action === "updatePassword" ? "Google didn't accept the saved password." : null,
      action,
      importId: action === "confirm" ? "fixture" : undefined,
    },
  }));
}

export const clearGoogleSaveOffer = (tabId: string) => useVaultSaveOffers.setState((s) => ({ ...s, [tabId]: null }));
