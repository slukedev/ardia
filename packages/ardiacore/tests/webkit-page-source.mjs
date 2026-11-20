import { readdirSync, readFileSync } from "node:fs";

const ios = new URL("../ios/", import.meta.url);
const swift = readdirSync(ios)
  .filter((name) => /^WebKitPageScript(?:\+\w+)?\.swift$/.test(name))
  .sort()
  .map((name) => readFileSync(new URL(name, ios), "utf8"))
  .join("\n");

const chromiumPageScript = readFileSync(new URL("page_script.js", ios), "utf8");
const kitStart = chromiumPageScript.indexOf("  const fieldProviderKit = ");
const kitEnd = chromiumPageScript.indexOf("  const nativeMutationObserver = ", kitStart);
if (kitStart < 0 || kitEnd < 0) throw new Error("the field provider kit isn't in page_script.js");
export const fieldProviderKit = chromiumPageScript.slice(kitStart, kitEnd);
const loadedAtLaunch = { fieldProviderKit };

const literal = (name) => {
  const found = swift.match(new RegExp(`static let ${name} = #"""\\n([\\s\\S]*?)\\n"""#`));
  if (!found) throw new Error(`WebKitPageScript.${name} not found`);
  return found[1].replace(/^\\#\((\w+)\)$/gm, (line, inner) => (inner in loadedAtLaunch ? loadedAtLaunch[inner] : literal(inner)));
};

const composed = (name, pattern) => {
  const found = swift.match(pattern);
  if (!found) throw new Error(`WebKitPageScript.${name} isn't composed the way this reader expects`);
  return found;
};

const sourceParts = composed("source", /static let source = \[([\w, ]+)\]\.joined\(separator: "\\n\\n"\)/);
const bridgeParts = composed("mediaBridge", /static let mediaBridge = (\w+(?: \+ \w+)*)\n/);

export const webKitPageScript = sourceParts[1].split(", ").map(literal).join("\n\n");
export const webKitMediaBridge = bridgeParts[1].split(" + ").map(literal).join("");
