#!/usr/bin/env python3
"""Usage: hsts-preload.py <transport_security_state_static.json> <out dir>

Writes subdomains.hosts and exact.hosts: Chromium's force-https preload entries,
lowercase, sorted by byte, one per line, raw-deflated for WebKitHostList.
"""
import json
import os
import sys
import zlib


def read_entries(path):
    with open(path, encoding="utf-8") as handle:
        lines = [line for line in handle.read().splitlines() if not line.lstrip().startswith("//")]
    return json.loads("\n".join(lines)).get("entries", [])


def split_entries(entries):
    subdomains, exact = set(), set()
    skipped = {"not-https": 0, "non-ascii": 0, "test": 0}
    for entry in entries:
        if entry.get("mode") != "force-https":
            skipped["not-https"] += 1
            continue
        if entry.get("policy") == "test":
            skipped["test"] += 1
            continue
        name = str(entry.get("name", "")).strip().lower().rstrip(".")
        if not name or not name.isascii() or not all(c.isalnum() or c in "-._" for c in name):
            skipped["non-ascii"] += 1
            continue
        (subdomains if entry.get("include_subdomains") else exact).add(name)
    exact -= subdomains
    return sorted(subdomains, key=str.encode), sorted(exact, key=str.encode), skipped


def write_hosts(path, hosts):
    raw = "\n".join(hosts).encode()
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    with open(path, "wb") as handle:
        handle.write(compressor.compress(raw) + compressor.flush())
    return len(raw)


def main():
    if len(sys.argv) != 3 or sys.argv[1] in ("-h", "--help"):
        sys.exit(__doc__)
    subdomains, exact, skipped = split_entries(read_entries(sys.argv[1]))
    os.makedirs(sys.argv[2], exist_ok=True)
    write_hosts(os.path.join(sys.argv[2], "subdomains.hosts"), subdomains)
    write_hosts(os.path.join(sys.argv[2], "exact.hosts"), exact)
    print("HSTS preload: %d with subdomains, %d exact, skipped %s" % (len(subdomains), len(exact), json.dumps(skipped, sort_keys=True)))


if __name__ == "__main__":
    main()
