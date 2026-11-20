enum WebKitAutofillScript {
  static let source = #"""
(() => {
  if (window.__ardiaAutofill) return;
  const post = (kind, data) => {
    try {
      window.webkit.messageHandlers.ardiaAutofill.postMessage({ kind, data });
    } catch (e) {}
  };
  const token = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
  const ADDRESS = new Set([
    "name", "given-name", "additional-name", "family-name", "organization", "street-address", "address-line1", "address-line2",
    "address-line3", "address-level2", "address-level1", "postal-code", "country", "tel", "tel-national", "tel-country-code",
    "tel-area-code", "tel-local", "email",
  ]);
  const CARD = new Set(["cc-name", "cc-given-name", "cc-family-name", "cc-number", "cc-exp", "cc-exp-month", "cc-exp-year", "cc-csc", "cc-type"]);
  const NOT_AUTOFILL = new Set(["username", "current-password", "new-password", "one-time-code", "off-autofill"]);
  const SECTION = /^(section-.+|shipping|billing)$/;
  const kindOf = (type) => (CARD.has(type) ? "card" : "address");
  const textual = /^(|text|email|tel|number)$/i;

  const visible = (el) => {
    if (!el || el.disabled || el.readOnly || !el.getClientRects().length) return false;
    const style = getComputedStyle(el);
    return style.visibility !== "hidden" && style.display !== "none" && Number(style.opacity) > 0.05;
  };
  const eligible = (el) => {
    if (el.tagName === "SELECT") return visible(el);
    if (el.tagName === "TEXTAREA") return visible(el);
    return el.tagName === "INPUT" && textual.test(el.getAttribute("type") || "") && visible(el);
  };

  const declared = (el) => {
    const tokens = String(el.getAttribute("autocomplete") || "").toLowerCase().trim().split(/\s+/).filter(Boolean);
    const section = tokens.filter((t) => SECTION.test(t)).join(" ");
    for (let i = tokens.length - 1; i >= 0; i--) {
      const type = tokens[i] === "country-name" ? "country" : tokens[i];
      if (ADDRESS.has(type) || CARD.has(type)) return { type, section };
      if (NOT_AUTOFILL.has(type)) return { type: null, section };
    }
    return null;
  };

  const labelText = (el) => {
    const parts = [];
    if (el.labels) for (const label of el.labels) parts.push(label.textContent);
    parts.push(el.getAttribute("aria-label"), el.getAttribute("placeholder"), el.getAttribute("title"));
    const by = el.getAttribute("aria-labelledby");
    if (by) for (const id of by.split(/\s+/)) parts.push(document.getElementById(id)?.textContent);
    if (!el.labels || !el.labels.length) {
      const before = el.previousElementSibling;
      if (before && !/^(INPUT|SELECT|TEXTAREA|BUTTON)$/.test(before.tagName)) parts.push(before.textContent);
      const cell = el.closest("td");
      if (cell && cell.previousElementSibling) parts.push(cell.previousElementSibling.textContent);
    }
    return parts.filter(Boolean).join(" ").replace(/\s+/g, " ").slice(0, 200);
  };

  const RULES = [
    [/coupon|promo|gift.?card|voucher|captcha|search|user.?name|login|passw|nickname|referr?al/, null],
    [/card.?holder|name.*\bon\b.*card|(?:card|cc).?(?:owner|name)|cc.?full.?name|name.?on.?card/, "cc-name"],
    [/verification|card.?identification|security.?code|card.?code|\bcvn\b|\bcvv\d?\b|\bcvc\d?\b|\bcsc\b|\bcvd\b|\bccv\b|^cvv|^cvc/, "cc-csc"],
    [/expir|\bexp\b|exp.?(?:date|mo|month|yr|year|mm|yy)|valid.?(?:thru|through)|mm\s*\/\s*yy/, "cc-exp"],
    [/(?:card|cc|acct).?(?:number|#|no\b|num)|ccnum|cardnum|credit.?card|debit.?card|^cc$|\bcard\b/, "cc-number"],
    [/e.?mail|courriel/, "email"],
    [/phone|mobile|\btel\b|telephone|contact.?number/, "tel"],
    [/company|business.?name|organi[sz]ation|employer/, "organization"],
    [/address.?(?:line)?.?(?:2|two)\b|addr.?2|suite|\bapt\b|apartment|\bunit\b|address.?ext|floor/, "address-line2"],
    [/address.?(?:line)?.?(?:3|three)\b|addr.?3/, "address-line3"],
    [/address.?(?:line)?.?(?:1|one)\b|addr.?1|street|^address$|\baddress\b|address$|house.?(?:number|name)/, "address-line1"],
    [/city|town|suburb|locality|municipality/, "address-level2"],
    [/zip|postal|post.?code|\bpcode\b|\bpin.?code\b|postcode/, "postal-code"],
    [/country|countries/, "country"],
    [/state(?!ment)|province|region|county|prefecture/, "address-level1"],
    [/first.?name|given.?name|\bfname\b|forename|first$/, "given-name"],
    [/middle.?name|\bmname\b|middle.?initial/, "additional-name"],
    [/last.?name|surname|family.?name|\blname\b|last$/, "family-name"],
    [/^name$|\bname\b|name$|full.?name|your.?name|customer.?name|recipient|contact.?name/, "name"],
  ];
  const MONTH = /month|\bmm\b(?!\s*\/)|\bmo\b|exp.?mo/;
  const YEAR = /year|\byy(?:yy)?\b|exp.?yr|exp.?year/;

  const guess = (el) => {
    const text = [el.getAttribute("name"), el.id, labelText(el)].filter(Boolean).join(" ").toLowerCase();
    const type = (el.getAttribute("type") || "").toLowerCase();
    if (type === "email") return "email";
    if (type === "tel") return "tel";
    for (const [pattern, result] of RULES) {
      if (!pattern.test(text)) continue;
      if (result !== "cc-exp") return result;
      if (el.tagName === "SELECT") {
        const values = Array.from(el.options, (o) => o.value + " " + o.text);
        if (values.some((v) => /\b20\d\d\b/.test(v)) && !values.some((v) => /\bjan|\b0?1\b.*\b0?2\b/i.test(v))) return "cc-exp-year";
        return "cc-exp-month";
      }
      if (/mm\s*[\/\-]\s*yy|exp\w*\s*date/.test(text) || el.maxLength === 5 || el.maxLength === 7) return "cc-exp";
      const month = MONTH.test(text);
      const year = YEAR.test(text);
      if (month && !year) return "cc-exp-month";
      if (year && !month) return "cc-exp-year";
      return "cc-exp";
    }
    return null;
  };

  const classifyAll = (form) => {
    const fields = [];
    for (const el of (form || document).querySelectorAll("input, select, textarea")) {
      if ((form ? el.form !== form : el.form) || !eligible(el)) continue;
      const stated = declared(el);
      if (stated && !stated.type) continue;
      const type = stated ? stated.type : guess(el);
      if (type) fields.push({ el, type, kind: kindOf(type), declared: !!stated, section: stated ? stated.section : "" });
    }
    const kept = fields.filter((f) => f.declared).length === fields.length || fields.length >= 3 ? fields : fields.filter((f) => f.declared);
    const sections = { address: { n: 0, seen: new Set() }, card: { n: 0, seen: new Set() } };
    for (const f of kept) {
      const s = sections[f.kind];
      const slot = f.type === "street-address" ? "address-line1" : f.type === "name" ? "given-name" : f.type;
      if (s.seen.has(slot) && !f.section) {
        s.n++;
        s.seen = new Set();
      }
      s.seen.add(slot);
      f.part = f.section || String(s.n);
    }
    return kept;
  };

  const hasPassword = (form) => Array.from((form || document).querySelectorAll("input[type=password]")).some(visible);

  const fieldFor = (el) => {
    if (!el || (el.tagName !== "INPUT" && el.tagName !== "TEXTAREA") || !eligible(el)) return null;
    const all = classifyAll(el.form);
    const field = all.find((f) => f.el === el);
    if (!field) return null;
    if (field.kind === "address" && /^(email|tel|name|given-name|family-name)$/.test(field.type) && hasPassword(el.form)) return null;
    const section = all.filter((f) => f.kind === field.kind && f.part === field.part);
    return { field, section };
  };

  const frameOffset = () => {
    let x = 0;
    let y = 0;
    let w = window;
    try {
      while (w !== w.top) {
        const frame = w.frameElement;
        if (!frame) return null;
        const r = frame.getBoundingClientRect();
        x += r.left + frame.clientLeft;
        y += r.top + frame.clientTop;
        w = w.parent;
      }
    } catch (e) {
      return null;
    }
    return { x, y };
  };

  let active = null;
  let open = false;
  let picking = false;
  const filled = new WeakMap();
  const hide = () => {
    if (open) post("field", { event: "hide", token });
    open = picking = false;
  };
  const report = (event, el) => {
    const found = fieldFor(el);
    if (!found) {
      if (active) hide();
      active = null;
      return;
    }
    const offset = frameOffset();
    if (!offset) return;
    active = { el, ...found };
    const r = el.getBoundingClientRect();
    post("field", {
      event, token, type: found.field.type, kind: found.field.kind,
      value: found.field.type === "cc-number" ? "" : String(el.value || "").slice(0, 100),
      needsNumber: found.section.some((f) => f.type === "cc-number"),
      x: r.left + offset.x, y: r.top + offset.y, width: r.width, height: r.height,
    });
  };

  addEventListener("pointerdown", (e) => {
    if (e.isTrusted && e.button === 0) report("show", e.target);
  }, true);
  addEventListener("input", (e) => {
    if (!e.isTrusted || !active || e.target !== active.el) return;
    filled.delete(e.target);
    report("input", e.target);
  }, true);
  addEventListener("keydown", (e) => {
    if (!e.isTrusted || !active || e.target !== active.el) return;
    const key = { ArrowDown: "down", ArrowUp: "up", Enter: "enter", Escape: "escape", Tab: "tab" }[e.key];
    if (!key) return;
    if (!open) {
      if (key === "down") {
        e.preventDefault();
        report("show", e.target);
      }
      return;
    }
    if (key !== "tab" && (key !== "enter" || picking)) {
      e.preventDefault();
      e.stopImmediatePropagation();
    }
    post("field", { event: "key", key, token });
  }, true);
  addEventListener("focusout", (e) => {
    if (active && e.target === active.el) hide();
  }, true);
  addEventListener("scroll", hide, true);
  addEventListener("resize", hide);
  addEventListener("pagehide", hide);

  const STATES = {
    al: "alabama", ak: "alaska", az: "arizona", ar: "arkansas", ca: "california", co: "colorado", ct: "connecticut", de: "delaware",
    dc: "district of columbia", fl: "florida", ga: "georgia", hi: "hawaii", id: "idaho", il: "illinois", in: "indiana", ia: "iowa",
    ks: "kansas", ky: "kentucky", la: "louisiana", me: "maine", md: "maryland", ma: "massachusetts", mi: "michigan", mn: "minnesota",
    ms: "mississippi", mo: "missouri", mt: "montana", ne: "nebraska", nv: "nevada", nh: "new hampshire", nj: "new jersey",
    nm: "new mexico", ny: "new york", nc: "north carolina", nd: "north dakota", oh: "ohio", ok: "oklahoma", or: "oregon",
    pa: "pennsylvania", ri: "rhode island", sc: "south carolina", sd: "south dakota", tn: "tennessee", tx: "texas", ut: "utah",
    vt: "vermont", va: "virginia", wa: "washington", wv: "west virginia", wi: "wisconsin", wy: "wyoming", pr: "puerto rico",
  };
  const norm = (s) => String(s || "").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
  const stateNames = (value) => {
    const v = norm(value);
    const full = STATES[v] || v;
    const abbr = Object.keys(STATES).find((k) => STATES[k] === full) || v;
    return [v, full, abbr];
  };
  const option = (select, tests) => {
    for (const test of tests) for (const o of select.options) if (!o.disabled && test(norm(o.value), norm(o.text))) return o.value;
    return null;
  };
  const pad = (n) => String(n).padStart(2, "0");
  const splitName = (full) => {
    const parts = String(full || "").trim().split(/\s+/).filter(Boolean);
    if (parts.length < 2) return { given: parts[0] || "", middle: "", family: "" };
    return { given: parts[0], middle: parts.slice(1, -1).join(" "), family: parts[parts.length - 1] };
  };
  const nationalPhone = (phone) => {
    const digits = String(phone || "").replace(/\D/g, "");
    return digits.length === 11 && digits[0] === "1" ? digits.slice(1) : digits;
  };
  const NETWORK_NAMES = { visa: "visa", mastercard: "mastercard master card mc", amex: "american express amex", discover: "discover", diners: "diners club", jcb: "jcb", unionpay: "unionpay union pay" };

  const valueFor = (type, v, el) => {
    const select = el.tagName === "SELECT";
    const max = el.maxLength > 0 ? el.maxLength : 0;
    const hint = ((el.getAttribute("placeholder") || "") + " " + labelText(el)).toLowerCase();
    const lines = String(v.street || "").split("\n").map((l) => l.trim()).filter(Boolean);
    const name = splitName(v.name);
    switch (type) {
      case "name": return v.name;
      case "given-name": return name.given;
      case "additional-name": return name.middle;
      case "family-name": return name.family;
      case "organization": return v.organization;
      case "street-address": return el.tagName === "TEXTAREA" ? lines.join("\n") : lines.join(", ");
      case "address-line1": return lines[0];
      case "address-line2": return lines[1];
      case "address-line3": return lines.slice(2).join(", ");
      case "address-level2": return v.city;
      case "postal-code": return v.postalCode;
      case "email": return v.email;
      case "tel": return max && max < String(v.phone || "").length ? nationalPhone(v.phone) : v.phone;
      case "tel-national": return nationalPhone(v.phone);
      case "tel-country-code": return v.phone && String(v.phone).trim().startsWith("+") ? "+" + String(v.phone).replace(/\D/g, "").slice(0, -10) : "+1";
      case "tel-area-code": return nationalPhone(v.phone).slice(0, 3);
      case "tel-local": return nationalPhone(v.phone).slice(3);
      case "address-level1": {
        if (!v.state) return null;
        if (!select) return v.state;
        const names = stateNames(v.state);
        return option(el, [(value, text) => names.includes(value) || names.includes(text)]);
      }
      case "country": {
        if (!v.country) return null;
        if (!select) return v.countryName || v.country;
        const code = norm(v.country);
        const full = norm(v.countryName);
        return option(el, [(value) => value === code, (value, text) => text === full || value === full, (value, text) => !!full && text.startsWith(full)]);
      }
      case "cc-name": return v.name;
      case "cc-given-name": return name.given;
      case "cc-family-name": return name.family;
      case "cc-number": return v.number || null;
      case "cc-exp": {
        if (!v.expMonth || !v.expYear) return null;
        const long = /yyyy|aaaa|jjjj/.test(hint) || max >= 7;
        const separator = /mm\s*-\s*yy/.test(hint) ? "-" : /mm\s+\/\s+yy/.test(hint) ? " / " : "/";
        const year = long ? String(v.expYear) : String(v.expYear).slice(-2);
        return pad(v.expMonth) + separator + year;
      }
      case "cc-exp-month": {
        if (!v.expMonth) return null;
        if (!select) return max === 1 ? String(v.expMonth) : pad(v.expMonth);
        const month = Number(v.expMonth);
        const names = [new Date(2000, month - 1, 1).toLocaleString("en", { month: "long" }).toLowerCase()];
        return option(el, [(value) => Number(value) === month, (value, text) => Number(text.split(" ")[0]) === month, (value, text) => names.some((n) => text.startsWith(n.slice(0, 3)))]);
      }
      case "cc-exp-year": {
        if (!v.expYear) return null;
        const full = String(v.expYear);
        if (!select) return max === 2 ? full.slice(-2) : full;
        return option(el, [(value) => value === full || value === full.slice(-2), (value, text) => text === full || text === full.slice(-2)]);
      }
      case "cc-type": {
        if (!select || !v.network) return null;
        const names = NETWORK_NAMES[v.network] || v.network;
        return option(el, [(value, text) => !!value && names.includes(value), (value, text) => !!text && names.split(" ").some((n) => text.includes(n))]);
      }
      default: return null;
    }
  };

  const setValue = (el, value) => {
    if (el.tagName === "SELECT") {
      if (el.value === value) return;
      el.value = value;
    } else {
      const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
      el.dispatchEvent(new Event("input", { bubbles: true }));
    }
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };

  const digits = (s) => String(s || "").replace(/\D/g, "");
  const luhn = (number) => {
    let sum = 0;
    for (let i = 0; i < number.length; i++) {
      let d = Number(number[number.length - 1 - i]);
      if (i % 2) {
        d *= 2;
        if (d > 9) d -= 9;
      }
      sum += d;
    }
    return number.length >= 12 && number.length <= 19 && sum % 10 === 0;
  };
  const shown = (el) => (el.tagName === "SELECT" ? el.options[el.selectedIndex]?.text || el.value : el.value);
  const readSection = (fields) => {
    const address = {};
    const card = {};
    const lines = [];
    const name = {};
    for (const f of fields) {
      const value = String(f.el.value || "").trim();
      if (!value) continue;
      switch (f.type) {
        case "name": address.name = value; break;
        case "given-name": name.given = value; break;
        case "additional-name": name.middle = value; break;
        case "family-name": name.family = value; break;
        case "organization": address.organization = value; break;
        case "street-address": lines.push(...value.split(/\n/)); break;
        case "address-line1": case "address-line2": case "address-line3": lines.push(value); break;
        case "address-level2": address.city = value; break;
        case "address-level1": address.state = value; break;
        case "postal-code": address.postalCode = value; break;
        case "country": address.country = value; address.countryText = String(shown(f.el)).trim(); break;
        case "tel": case "tel-national": address.phone = value; break;
        case "email": address.email = value; break;
        case "cc-name": card.name = value; break;
        case "cc-given-name": card.given = value; break;
        case "cc-family-name": card.family = value; break;
        case "cc-number": card.number = digits(value); card.filled = filled.get(f.el) === value; break;
        case "cc-exp": {
          const m = value.match(/^\s*(\d{1,2})\s*[\/\-. ]\s*(\d{2}|\d{4})\s*$/);
          if (m) {
            card.expMonth = Number(m[1]);
            card.expYear = Number(m[2].length === 2 ? "20" + m[2] : m[2]);
          }
          break;
        }
        case "cc-exp-month": card.expMonth = Number(value) || Number(String(shown(f.el)).split(/\D/)[0]) || 0; break;
        case "cc-exp-year": card.expYear = Number(value.length === 2 ? "20" + value : value) || 0; break;
      }
    }
    if (!address.name && (name.given || name.family)) address.name = [name.given, name.middle, name.family].filter(Boolean).join(" ");
    if (!card.name && (card.given || card.family)) card.name = [card.given, card.family].filter(Boolean).join(" ");
    delete card.given;
    delete card.family;
    if (lines.length) address.street = lines.join("\n");
    if (card.number && !luhn(card.number)) delete card.number;
    return { address, card };
  };

  const recentSubmits = new WeakMap();
  const submitted = (form) => {
    const key = form || document;
    const now = Date.now();
    if (now - (recentSubmits.get(key) || 0) < 1500) return;
    const all = classifyAll(form);
    if (!all.length) return;
    const parts = (kind) => {
      const groups = new Map();
      for (const f of all) if (f.kind === kind) (groups.get(f.part) || groups.set(f.part, []).get(f.part)).push(f);
      return Array.from(groups.values());
    };
    const best = (kind, pick) => parts(kind).map(readSection).map(pick).sort((a, b) => Object.keys(b).length - Object.keys(a).length)[0] || {};
    const address = best("address", (s) => s.address);
    const card = best("card", (s) => s.card);
    if (!address.street && !card.number) return;
    recentSubmits.set(key, now);
    post("submit", { token, address: address.street ? address : null, card: card.number ? card : null });
  };
  addEventListener("submit", (e) => submitted(e.target), true);
  addEventListener("click", (e) => {
    if (!e.isTrusted) return;
    const button = e.target && e.target.closest && e.target.closest("button, input[type=submit]");
    if (button && (button.type === "submit" || button.tagName === "INPUT")) submitted(button.form);
  }, true);

  window.__ardiaAutofill = {
    dropdown(t, isOpen, hasPick) {
      if (t !== token) return;
      open = !!isOpen;
      picking = !!hasPick;
    },
    fill(t, kind, values) {
      if (t !== token || !active || !active.el.isConnected) return 0;
      const found = fieldFor(active.el);
      if (!found || found.field.kind !== kind) return 0;
      let count = 0;
      for (const f of found.section) {
        if (f.el !== active.el && f.el.tagName !== "SELECT" && f.el.value && filled.get(f.el) !== f.el.value) continue;
        const value = valueFor(f.type, values, f.el);
        if (value == null || value === "") continue;
        setValue(f.el, String(value));
        if (f.el.tagName !== "SELECT") filled.set(f.el, f.el.value);
        count++;
      }
      open = picking = false;
      return count;
    },
  };
})();
"""#
}
