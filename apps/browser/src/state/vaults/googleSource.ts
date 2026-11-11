import type { MenuItem } from "../app/system";
import { setGoogleSource, type VaultGoogleSourceChoice, type VaultProviderState } from "../../platform/vaults";
import { refreshProvider, unlockProvider } from "./actions";
import { applyProviderState } from "./store";
import { chromeStatusLine } from "./google";

export const CHROME_SOURCE_LINE = "Google Chrome";
export const CHROME_FALLBACK_LINE = "Couldn't read Chrome";

type StatusFields = Pick<VaultProviderState, "state" | "account" | "message" | "refreshedAt" | "hold" | "source" | "fallback">;

export function googleStatusLine(p: StatusFields, now = Date.now()): string | undefined {
  if (p.state !== "unlocked") return chromeStatusLine(p, now);
  if (p.source === "chrome") return [p.account, CHROME_SOURCE_LINE].filter(Boolean).join(" · ");
  if (p.source === "web" && p.fallback) return chromeStatusLine({ ...p, account: [p.account, CHROME_FALLBACK_LINE].filter(Boolean).join(" · ") }, now);
  return chromeStatusLine(p, now);
}

const SOURCE_PREFIX = "source.";

const CHOICES: { choice: VaultGoogleSourceChoice; title: string }[] = [
  { choice: "automatic", title: "Automatic" },
  { choice: "chrome", title: "Google Chrome" },
  { choice: "web", title: "passwords.google.com" },
];

export function googleSourceMenu(p: Pick<VaultProviderState, "sourceChoice" | "fallback">): MenuItem {
  const current = p.sourceChoice ?? "automatic";
  return {
    id: "source",
    title: "Passwords From",
    symbol: "arrow.triangle.branch",
    children: [
      ...CHOICES.map(({ choice, title }) => ({ id: SOURCE_PREFIX + choice, title, checked: choice === current })),
      ...(p.fallback ? [{ separator: true as const }, { id: "source.why", title: p.fallback, enabled: false }] : []),
    ],
  };
}

export function sourceChoiceOf(menuId: string | null | undefined): VaultGoogleSourceChoice | null {
  const choice = menuId?.startsWith(SOURCE_PREFIX) ? menuId.slice(SOURCE_PREFIX.length) : "";
  return CHOICES.some((c) => c.choice === choice) ? (choice as VaultGoogleSourceChoice) : null;
}

export async function chooseGoogleSource(provider: VaultProviderState, choice: VaultGoogleSourceChoice) {
  if ((provider.sourceChoice ?? "automatic") === choice && !provider.fallback) return;
  const wasOpen = provider.state === "unlocked";
  const state = await setGoogleSource(choice).catch(() => null);
  if (!state) return void refreshProvider(provider.id);
  applyProviderState(state);
  if (wasOpen && state.state === "locked") await unlockProvider(provider.id, null);
}
