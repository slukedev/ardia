import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { inflateRawSync } from "node:zlib";

const path = (name) => fileURLToPath(new URL(name, import.meta.url));
const converter = path("../scripts/ubol-webkit.py");
const fixture = path("./fixtures/ubol-webkit");
const python = process.env.PYTHON || "python3";
const hasPython = spawnSync(python, ["-I", "-c", "pass"]).status === 0;

function convert(out) {
  const run = spawnSync(python, ["-I", converter, fixture, out, "1"], { encoding: "utf8", timeout: 60_000 });
  assert.equal(run.status, 0, run.stderr);
  const lines = inflateRawSync(readFileSync(join(out, "sample.rules"))).toString("utf8").split("\n").filter(Boolean);
  return lines.map((line) => {
    const tab = line.indexOf("\t");
    return { tag: line[0], header: line.slice(1, tab), rules: JSON.parse(`[${line.slice(tab + 1)}]`) };
  });
}

test("the uBOL converter emits only rules WebKit can compile, and the same bytes every run", { skip: !hasPython && `${python} is not installed` }, () => {
  const dir = mkdtempSync(join(process.env.TMPDIR || tmpdir(), "ardiacore-ubol-webkit-"));
  try {
    const lines = convert(join(dir, "a"));
    const filters = lines.flatMap((line) => line.rules.map((rule) => rule.trigger["url-filter"]));
    for (const filter of filters) {
      assert.ok(filter.length > 0, "an empty url-filter fails the whole list's compile");
      assert.match(filter, /^[\x20-\x7e]+$/, `${JSON.stringify(filter)} has a character WebKit rejects`);
    }
    assert.ok(!filters.includes("nads"), "a \\n escape is not the letter n");
    assert.ok(!filters.includes("^"), "a NUL in a regex does not become a start anchor");
    assert.ok(!filters.some((filter) => filter.includes("ads") && !filter.includes("example")), "lookaheads and reversed braces are dropped");
    assert.ok(filters.includes("^tracker\\.example/") && filters.includes("\\.tracker\\.example/"), "(^|\\.) expands to two patterns");
    assert.ok(filters.includes("\\.gif$") && filters.includes("\\.png$"));
    assert.ok(!filters.includes("/banner/"), "a rule whose excluded initiators can't all be expressed is skipped, not widened");
    const grouped = lines.find((line) => line.tag === "p");
    assert.deepEqual(grouped?.rules.map((rule) => rule.action.type), ["block", "ignore-previous-rules"]);

    const group = (filter) => {
      const found = lines.find((line) => line.tag === "p" && line.rules.some((rule) => rule.action.type === "block" && rule.trigger["url-filter"].includes(filter)));
      assert.ok(found, `no exclusion group blocks ${filter}`);
      const [priority, set, rank] = found.header.split(".").map(Number);
      return { priority, set, rank };
    };
    const pixel = group("/pixel/");
    const track = group("cdn\\.example/track\\.js");
    const other = group("promo\\.other");
    assert.notEqual(pixel.set, track.set, "each group's exclusion would undo the other's block, so they never share a list");
    assert.equal(other.set, pixel.set, "a group whose exclusion can't touch /pixel/ shares its list");
    assert.ok(other.rank < pixel.rank, "and comes first, because /pixel/'s exclusion of cdn.example must not follow a block it could undo");
    assert.ok(lines.filter((line) => line.tag === "b").every((line) => /^\d+$/.test(line.header)), "plain blocks carry no set, so they never join a group's list");

    const again = join(dir, "b");
    convert(again);
    assert.deepEqual(readFileSync(join(again, "sample.rules")), readFileSync(join(dir, "a", "sample.rules")));
    assert.deepEqual(readFileSync(join(again, "rulesets.json")), readFileSync(join(dir, "a", "rulesets.json")));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
