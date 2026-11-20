import { counted, onConsentPeriodChange, type ConsentToken } from "./choice";

const WIRE = {
  blockerStrictBlocked: "webkit_blocker_strict_blocks",
  blockerStrictProceed: "webkit_blocker_strict_proceeds",
  blockerCosmeticApplied: "webkit_blocker_cosmetic_pages",
  blockerUserFilters: "webkit_blocker_user_filter_loads",
  blockerCompileFailed: "webkit_blocker_compile_failures",
  blockerUserFiltersFailed: "webkit_blocker_user_filter_failures",
  blockerUserFiltersIsolated: "webkit_blocker_user_filter_isolations",
} as const;

export type WebKitContentBlockerCount = keyof typeof WIRE;
type Wire = (typeof WIRE)[WebKitContentBlockerCount];

const none = () => Object.fromEntries(Object.values(WIRE).map((wire) => [wire, 0])) as Record<Wire, number>;
let tally = none();

onConsentPeriodChange(() => (tally = none()));

export const isWebKitContentBlockerCount = (name: string): name is WebKitContentBlockerCount => Object.hasOwn(WIRE, name);

export function noteWebKitContentBlockerCount(name: WebKitContentBlockerCount, consent: ConsentToken | null) {
  counted(consent, () => void tally[WIRE[name]]++);
}

export function takeWebKitContentBlockerCounts(): Record<Wire, number> {
  const taken = tally;
  tally = none();
  return taken;
}
