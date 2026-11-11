import csv
import hashlib
import html
import io
import http.server
import json
import os
import secrets
import sys
import time
import urllib.parse

USAGE = """Local stand-in for passwords.google.com and accounts.google.com, for hidden test instances.

usage: server.py <port> <log.jsonl>

Serves the options page on http://127.0.0.1:<port> and the password check on http://localhost:<port>.
Start Ardia with ARDIA_TEST googlePasswordsURL=http://127.0.0.1:<port>,googleAccountsURL=http://localhost:<port>.
FIXTURE_GOOGLE_PASSWORD sets the accepted password (default fixture-google-pass); FIXTURE_RAPT_SECONDS how long a
check's rapt token is accepted (default 300). Rows imported through the import dialog are added to later exports.
The list page (/) shows one row per site like passwords.google.com, built from the export's rows, and
POST /forget?site=<host> deletes that site's rows, as deleting it on passwords.google.com would.
Every request and page report is appended to the log as JSON lines (imported rows are logged without passwords)."""

if len(sys.argv) != 3 or sys.argv[1] in ("-h", "--help"):
    print(USAGE)
    sys.exit(0 if len(sys.argv) == 2 else 64)

PORT = int(sys.argv[1])
OUT = sys.argv[2]
PASSWORD = os.environ.get("FIXTURE_GOOGLE_PASSWORD", "fixture-google-pass")
RAPT_SECONDS = float(os.environ.get("FIXTURE_RAPT_SECONDS", "300"))
PASSWORDS = f"http://127.0.0.1:{PORT}"
ACCOUNTS = f"http://localhost:{PORT}"
RAPTS = {}
IMPORTED = []
FORGOTTEN = set()

EXPORT_CSV = (
    "name,url,username,password,note\n"
    "alpha.example,https://alpha.example/,ann@example.com,\"pa,ss \"\"one\"\"\",\n"
    "\"Beta, Inc.\",https://beta.example/login,bob,hunter2,\"line one\nline two\"\n"
    "app,android://hash@com.example.app/,carol,app-only,\n"
    "localhost,http://localhost:8790/,dave,fixture-pass,\n"
)


def log(entry):
    with open(OUT, "a") as f:
        f.write(json.dumps({"at": time.time(), **entry}) + "\n")


def fresh_rapt(q):
    token = (q.get("rapt") or [""])[0]
    issued = RAPTS.get(token)
    return issued is not None and time.time() - issued < RAPT_SECONDS


STYLE = "<style>[role=dialog]{position:fixed;inset:20% 20%;background:#fff;border:1px solid #888;padding:16px}</style>"

OPTIONS = """<!doctype html><title>Password Manager options</title>""" + STYLE + """
<h1>Options</h1>
<div>Import passwords <button jsname="Pr7Yme" id="import">Import</button></div>
<div id="exportRow">Export passwords </div>
<div>On-device encryption <button>Set up</button></div>
<div role="dialog" id="dlg" hidden>
  <h2>Export Passwords</h2>
  <p>Your passwords will be visible to anyone who can see the exported file.</p>
  <button id="cancel">Cancel</button>
  <button id="go">Export</button>
</div>
<script>
const $ = (id) => document.getElementById(id);
const fresh = @@fresh@@;
const report = (what, extra) => fetch("/report", { method: "POST", body: JSON.stringify({ what, ...extra }) });
const challenge = (next) => { location.href = "@@accounts@@/v3/signin/challenge/pwd?TL=fixture&continue=" + encodeURIComponent(next); };
$("import").onclick = () => challenge("@@passwords@@/options?import=1");
setTimeout(() => {
  const b = document.createElement("button");
  b.setAttribute("aria-label", "Export");
  b.textContent = "⤓";
  b.onclick = () => { $("dlg").hidden = false; report("exportDialog"); };
  $("exportRow").appendChild(b);
}, 600);
$("cancel").onclick = () => ($("dlg").hidden = true);
$("go").onclick = () => {
  $("dlg").hidden = true;
  if (!fresh) return challenge("@@passwords@@/options?export=1");
  fetch("/export" + location.search, { method: "POST" }).then((r) => r.text()).then((csv) => {
    const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "Google Passwords.csv";
    document.body.appendChild(a);
    a.click();
    report("exported", { downloadAttempted: true });
  });
};
</script>"""

IMPORT = """<!doctype html><title>Password Manager options</title>""" + STYLE + """
<h1>Options</h1>
<div id="row">Import passwords <span id="spin" aria-label="Preparing passwords...">...</span></div>
<input type="file" accept=".csv" jsname="qGt1Bf" hidden aria-hidden="true" id="file">
<div role="dialog" id="dlg" hidden>
  <h2>Import passwords</h2>
  <p id="msg">To import passwords to your Google Account, select a CSV file.</p>
  <p id="name"></p>
  <button aria-label="Close dialog" id="cancel">Cancel</button>
  <button id="select">Select file</button>
  <button id="go" hidden>Import</button>
  <button id="done" hidden>Done</button>
</div>
<script>
const $ = (id) => document.getElementById(id);
const file = $("file");
let chosen = "";
const report = (what, extra) => fetch("/report", { method: "POST", body: JSON.stringify({ what, ...extra }) });
setTimeout(() => {
  $("spin").remove();
  $("dlg").hidden = false;
  report("dialog");
  file.click();
}, 400);
$("select").onclick = () => file.click();
$("cancel").onclick = () => ($("dlg").hidden = true);
file.addEventListener("change", async () => {
  const f = file.files[0];
  if (!f) return;
  const text = await f.text();
  chosen = text;
  $("name").textContent = f.name;
  $("msg").textContent = "";
  $("select").textContent = "Select new file";
  $("go").hidden = false;
  report("fileChosen", { name: f.name, type: f.type, rows: text.trim().split("\\n").length - 1 });
});
$("go").onclick = async () => {
  await fetch("/imported", { method: "POST", body: chosen });
  await report("imported");
  $("name").textContent = "";
  $("msg").textContent = "1 password imported";
  for (const id of ["select", "cancel", "go"]) $(id).hidden = true;
  $("done").hidden = false;
};
$("done").onclick = () => { $("dlg").hidden = true; report("done"); };
</script>"""

CHALLENGE = """<!doctype html><title>Sign in</title>
<h1>To continue, first verify it's you</h1>
<form onsubmit="return false"><input type="password" name="Passwd" id="pw" autocomplete="current-password">
<div id="err"></div>
<div id="passwordNext"><button type="button" id="next">Next</button></div></form>
<script>
document.getElementById("next").onclick = () => {
  const pw = document.getElementById("pw");
  fetch("/check", { method: "POST", body: pw.value }).then((r) => r.json()).then((answer) => {
    if (answer.rapt) {
      const next = new URL(new URLSearchParams(location.search).get("continue"));
      next.searchParams.set("rapt", answer.rapt);
      location.href = next.href;
    } else {
      pw.setAttribute("aria-invalid", "true");
      document.getElementById("err").textContent = "Wrong password. Try again or click Forgot password to reset it.";
    }
  });
};
</script>"""

LOGIN = """<!doctype html><title>Fixture login</title>
<form id="f" onsubmit="event.preventDefault(); document.title = 'submitted'">
<input id="u" name="username" autocomplete="username"><input id="p" type="password" name="password" autocomplete="current-password">
<button id="go" type="submit">Sign in</button></form>"""


def site_of(url):
    host = (urllib.parse.urlparse(url).hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


def rows():
    text = EXPORT_CSV + "".join(IMPORTED)
    kept = []
    for row in csv.DictReader(io.StringIO(text)):
        if urllib.parse.urlparse(row["url"]).scheme in ("http", "https") and site_of(row["url"]) not in FORGOTTEN:
            kept.append(row)
    return kept


def export_csv():
    out = io.StringIO()
    writer = csv.DictWriter(out, fieldnames=["name", "url", "username", "password", "note"], lineterminator="\n")
    writer.writeheader()
    text = EXPORT_CSV + "".join(IMPORTED)
    for row in csv.DictReader(io.StringIO(text)):
        if site_of(row["url"]) not in FORGOTTEN:
            writer.writerow(row)
    return out.getvalue()


def list_page():
    sites = {}
    for row in rows():
        sites.setdefault(site_of(row["url"]), []).append(row)
    items = []
    for name in sorted(sites):
        group = hashlib.sha256(name.encode()).hexdigest()[:44]
        count = len(sites[name])
        extra = f'<div class="count">{count} accounts</div>' if count > 1 else ""
        items.append(
            f'<li class="K6ZZTd" data-id="{group}" jsname="Sf4MPd"><div jscontroller="FS1FEb">'
            f'<a href="password/{group}?ep=1" class="RlFDUe"><div class="iAwpk"><div class="eP6Eff"><div class="PLEKud">'
            f'<img alt="" role="presentation" src="data:,"></div></div><div class="GqRghe"><div class="mMsbvc">'
            f'<div class="v2z6vb">{html.escape(name)}</div>{extra}</div></div><div class="kvjuQc"><div class="Ivdcjd">'
            f'<span class="notranslate" aria-hidden="true"><svg width="24" height="24"><path d="M0 0"></path></svg></span></div></div></div></a>'
            f'</div><hr></li>'
        )
    body = "".join(items)
    return (
        "<!doctype html><title>Password Manager</title><h1>Password Manager</h1>"
        '<input type="text" aria-label="Search passwords"><div id="list"></div>'
        "<script>setTimeout(() => { document.getElementById('list').innerHTML = "
        + json.dumps('<ul class="u7hyyf">' + body + "</ul>")
        + "; }, 500);</script>"
    )


def fill(page, subs):
    for k, v in subs.items():
        page = page.replace("@@" + k + "@@", v)
    return page


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, body, code=200, headers=None, kind="text/html; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def to_challenge(self, next_url):
        self.send("", 302, {"Location": f"{ACCOUNTS}/v3/signin/challenge/pwd?TL=fixture&continue=" + urllib.parse.quote(next_url, safe="")})

    def do_GET(self):
        host = self.headers.get("Host", "")
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        fresh = fresh_rapt(q)
        log({"get": host + url.path, "query": sorted(q.keys()), "freshRapt": fresh})
        subs = {"accounts": ACCOUNTS, "passwords": PASSWORDS, "fresh": json.dumps(fresh)}
        if host.startswith("127.0.0.1") and url.path == "/":
            log({"listed": len(rows())})
            return self.send(list_page())
        if host.startswith("127.0.0.1") and url.path.startswith("/password/"):
            return self.to_challenge(PASSWORDS + url.path)
        if host.startswith("127.0.0.1") and url.path == "/options":
            if q.get("import") == ["1"]:
                return self.send(fill(IMPORT, subs)) if fresh else self.to_challenge(f"{PASSWORDS}/options?import=1")
            return self.send(fill(OPTIONS, subs))
        if host.startswith("localhost") and url.path == "/v3/signin/challenge/pwd":
            return self.send(CHALLENGE)
        if url.path == "/login":
            return self.send(LOGIN)
        self.send("not found", 404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0") or 0))
        url = urllib.parse.urlparse(self.path)
        if url.path == "/export":
            fresh = fresh_rapt(urllib.parse.parse_qs(url.query))
            log({"export": "served" if fresh else "refused"})
            return self.send(export_csv() if fresh else "", 200 if fresh else 403, kind="text/plain; charset=utf-8")
        if url.path == "/imported":
            lines = body.decode(errors="replace").splitlines()[1:]
            IMPORTED.extend(line + "\n" for line in lines if line.strip())
            log({"importedRows": len(lines)})
            self.send_response(204)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        if url.path == "/forget":
            site = (urllib.parse.parse_qs(url.query).get("site") or [""])[0].lower()
            FORGOTTEN.add(site)
            log({"forgot": site})
            self.send_response(204)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        if url.path == "/check":
            ok = body.decode(errors="replace") == PASSWORD
            token = None
            if ok:
                token = "fx" + secrets.token_urlsafe(12)
                RAPTS[token] = time.time()
            log({"check": "accepted" if ok else "rejected"})
            return self.send(json.dumps({"rapt": token}), kind="application/json")
        try:
            entry = json.loads(body)
        except Exception:
            entry = {"raw": body.decode(errors="replace")[:200]}
        log({"report": entry})
        self.send_response(204)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
