import { counted, onConsentPeriodChange, type ConsentToken } from "./choice";

const WIRE = {
  autofillAddressFill: "webkit_autofill_address_fills",
  autofillCardFill: "webkit_autofill_card_fills",
  autofillCardReauthRefused: "webkit_autofill_card_reauths_refused",
  autofillAddressSaveOffer: "webkit_autofill_address_save_offers",
  autofillAddressSave: "webkit_autofill_address_saves",
  autofillCardSaveOffer: "webkit_autofill_card_save_offers",
  autofillCardSave: "webkit_autofill_card_saves",
  autofillSaveSuppressed: "webkit_autofill_save_suppressed",
} as const;

export type WebKitAutofillCount = keyof typeof WIRE;
type Wire = (typeof WIRE)[WebKitAutofillCount];

const none = () => Object.fromEntries(Object.values(WIRE).map((wire) => [wire, 0])) as Record<Wire, number>;
let tally = none();

onConsentPeriodChange(() => (tally = none()));

export const isWebKitAutofillCount = (name: string): name is WebKitAutofillCount => Object.hasOwn(WIRE, name);

export function noteWebKitAutofillCount(name: WebKitAutofillCount, consent: ConsentToken | null) {
  counted(consent, () => void tally[WIRE[name]]++);
}

export function takeWebKitAutofillCounts(): Record<Wire, number> {
  const taken = tally;
  tally = none();
  return taken;
}
