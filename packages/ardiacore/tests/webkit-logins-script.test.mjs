import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const swift = readFileSync(new URL("../ios/WebKitLogins.swift", import.meta.url), "utf8");
const source = swift.slice(swift.indexOf('static let script = #"""\n') + 25, swift.indexOf('\n"""#'));

function page({ origin, fields }) {
  const inputs = fields.map(({ type, name = "", id = "", autocomplete = "", shown = true, value = "" }) => {
    const attributes = { type, name, autocomplete };
    return {
      tagName: "INPUT",
      type,
      name,
      id,
      autocomplete,
      value,
      disabled: false,
      readOnly: false,
      form: null,
      getAttribute: (key) => attributes[key] || null,
      getClientRects: () => (shown ? [{}] : []),
      compareDocumentPosition: () => 4,
    };
  });
  const document = {
    querySelectorAll: (selector) => (selector === "input[type=password]" ? inputs.filter((el) => el.type === "password") : inputs),
  };
  const window = {};
  const posted = [];
  const listeners = {};
  window.webkit = { messageHandlers: { ardia: { postMessage: (message) => posted.push(message) } } };
  const context = vm.createContext({
    window,
    document,
    location: { origin },
    addEventListener: (name, listener) => (listeners[name] = listener),
    Node: { DOCUMENT_POSITION_FOLLOWING: 4 },
    HTMLInputElement: { prototype: {} },
  });
  vm.runInContext(source, context);
  return { logins: window.__ardiaLogins, posted, listeners };
}

const loginForm = [{ type: "text", name: "user" }, { type: "password", name: "pass", id: "pw", autocomplete: "current-password", value: "s3cret" }];
const submitted = (() => {
  const { posted, listeners } = page({ origin: "https://bank.test", fields: loginForm });
  listeners.submit({ target: null });
  return posted.find((m) => m.kind === "loginSubmit").data.field;
})();

const cases = [
  { name: "the login form came back after the submit", origin: "https://bank.test", fields: loginForm, shown: true },
  { name: "the next page has no password field", origin: "https://bank.test", fields: [{ type: "text" }], shown: false },
  { name: "the password field is still in the page but hidden", origin: "https://bank.test", fields: [{ ...loginForm[1], shown: false }], shown: false },
  { name: "the tab landed on another origin", origin: "https://app.bank.test", fields: loginForm, shown: false },
  { name: "the next page asks for a one-time code in a password field", origin: "https://bank.test", fields: [{ type: "password", name: "otp", autocomplete: "one-time-code" }], shown: false },
];

for (const { name, origin, fields, shown } of cases) {
  test(`a save-password offer waits for the submitted login form to go: ${name}`, () => {
    assert.equal(page({ origin, fields }).logins.formShown("https://bank.test", submitted), shown);
  });
}
