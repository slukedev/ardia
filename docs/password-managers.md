# Password managers

Ardia fills logins from 1Password, Bitwarden (bitwarden.com, bitwarden.eu, self-hosted servers and Vaultwarden),
Proton Pass and Google Password Manager. It talks to the first three through the vendor's own command-line tool (`op`,
`bw`, `pass-cli`), so Ardia never implements a vault format and never syncs a vault. Google has no CLI or API, so
Google Password Manager has two sources. When Google Chrome is installed with a profile signed in to a Google Account
(its `Login Data For Account` exists), Ardia reads Chrome's own stores, opened with Chrome's Safe Storage key: the
account store first, then the on-device `Login Data`, live and with no rate limit. Otherwise, or when Chrome can't be
read, it goes through passwords.google.com in a page Ardia never shows: reading is the site's own CSV export, caught
in memory. Saving is always the site's CSV import, and on the Chrome source the saved login shows up in Chrome's
account store once it syncs down. See "Choosing the source" below.

### Choosing the source

`GoogleSourceRules` (pure, `swift test`) picks it from the person's choice, what Chrome looks like
(`ChromeReadiness`: `notInstalled`, `unreadable` when macOS won't open Chrome's folder, `noProfile`, `deviceOnly` for
a profile with no Google Account, `account`), the Chrome failure seen this launch (`ChromeFailure`) and whether the
web path is set up (a Google password saved in Ardia):

| Choice (⋯ › Passwords From) | Picks |
| --- | --- |
| Automatic (default, `vaults.googleSource {choice: "automatic"}`) | Chrome when its profile has the account store and nothing failed; else the web when it is set up; else Chrome's on-device logins; else nothing (`signedOut`) |
| Google Chrome | Chrome (account or on-device) or nothing, never the web |
| passwords.google.com | the web or nothing |

A Chrome failure (keychain denied or missing, a key that opens no row, macOS refusing the folder, Chrome signed out
mid-session, or an empty account store while the web is set up, which means Chrome isn't saving passwords to the
account) is kept in memory until the next launch, a sign out or another choice, so Automatic moves to the web without
asking again. It happens inside the same unlock or list: an unlock that fails on Chrome goes on to the web unlock, and
a list that fails on Chrome reads the web when the session holds the Google password. Picking Automatic again from
the menu, or an unlock with no source left, clears it and tries Chrome again. A busy Chrome store (still busy after
the retry) is not a failure: the list stays as it was and the error shows.

The state says which source is in use: `source` (`chrome` or `web`), `sourceChoice`, and `fallback`, Chrome's
problem in one sentence while Automatic is on the web because of it. The Settings row reads `me@gmail.com · Google
Chrome` on Chrome and `me@gmail.com · Couldn't read Chrome · Updated at 9:05` after a fallback; the reason is the
last, disabled line of ⋯ › Passwords From. Chrome never sets `syncAgainAt` or `hold`, so the hourly sync alert and
Confirm… never show there. Changing the choice keeps the session when it already holds what the new source needs and
refetches; otherwise it locks and Settings unlocks again at once.

The session (`GoogleSession`) is `web:<password>` on the web, the hex Chrome key on Chrome, and
`chrome:<key>;web:<password>` when a Chrome unlock that passed the owner check (Touch ID copy, or Safe Storage read
without macOS asking) also reads the saved Google password with that same check. Only the Chrome key goes to the
Touch ID copy. When macOS's keychain prompt was the approval, the Google password isn't read then, and a save reads it
after its own owner check if Google asks.

## Architecture

```
apps/browser (JS)                       packages/ardiacore/ios (Swift, module ArdiaVaults)
  platform/vaults.ts  ── call("vaults.*") ──>  VaultsModule ──> VaultBroker (actor)
                      ── signIn / unlock ──>                      │  item cache, per-provider lanes,
                      <── vaults.changed ───                      │  state cache, fill and save checks
                      <── vaults.itemsChanged                     v
ArdiaWebView+PageTab ── fillValues / save ──────────────> VaultRegistry.providers
                                                           OnePasswordVault, BitwardenVault, ProtonPassVault,
                                                           GooglePasswordManagerVault
                                                                  │  (protocol VaultProvider)
                                                                  v
                                                           VaultCLI ──> VaultCommand ──> Process (op, bw, pass-cli)
                                                                  └──> Chrome's User Data folder (google: no process)
```

| File | Role |
| --- | --- |
| `VaultsModule.swift` | The Expo module `ArdiaVaults`: the `vaults.*` call table, the `vaults` event channel, and the two secret-taking functions `signIn(provider, fieldsJSON)` and `unlock(provider, password)`. |
| `VaultBroker.swift` | The one actor every caller goes through. Caches provider states and item lists (served at once, refreshed in the background after 60 s), serialises every CLI call per provider through a `VaultLane`, emits `vaults.changed` and `vaults.itemsChanged`, and runs the fill and save checks. |
| `VaultProvider.swift` | The protocol a manager implements, plus shared helpers (`makeState`, `signedIn`, `needs`, `failed`, `checked`). |
| `VaultRegistry.swift` | The list of managers. |
| `VaultCLI.swift`, `VaultLocation.swift` | Where the manager lives (`binary(path)` for a CLI, `dataFolder(path)` for one with no binary) plus its environment and the provider's slice of the session store. Providers only ever run commands through it; `run` on a data folder answers "not launched". |
| `GooglePasswordManagerVault.swift` | Google Password Manager: profile choice, unlock with Chrome's Safe Storage key, items from both of Chrome's login stores. Its saves go through `GoogleWebImporter` (`VaultBroker.saveToGoogle`), never through the provider's lane. |
| `ChromeLogins.swift`, `ChromeProfiles.swift` | Pure, Foundation-only: the snapshot reader for Chrome's `logins` table, v10 AES-CBC decryption, row to `VaultItem` mapping and ids, Chrome time, `Local State` parsing and profile choice. Built and tested on their own by `packages/ardiacore/Package.swift` (`swift test`, part of `pnpm -C packages/ardiacore test`). |
| `ChromeInstallation.swift`, `ChromeSafeStorage.swift` | Where Chrome and its User Data folder are (the fixture copy in a test instance), and reading the "Chrome Safe Storage" keychain item. |
| `GoogleWebImporter.swift`, `GoogleWebImportRules.swift`, `GoogleWebImportScripts.swift` | Reading from and saving to Google: the hidden page's driver (one operation at a time, import queue and dedupe, the export job, the kept `rapt`, the persisted limits, timeouts, events), and the pure parts: the selector table, page-state classification, the import step machine, the in-memory CSV and the error codes (`swift test`). |
| `GoogleWebExportRules.swift` | Pure, tested with `swift test`: `GoogleWebLimits` (every rate limit for Google's site in one type), `GoogleExportFlow` (the export step machine), `GoogleRapt` (reading and adding the check's token), and `GoogleExportCSV` (the RFC 4180 parser and rows to `Google Account` items). |
| `ArdiaHiddenPage.h/.mm` | A Chrome tab of the default profile that is never shown: opened in a stray window with no `NSWindow` on screen and parked off screen (`ArdiaTabParking keepOffscreen`), answering its page script's hello with its own config, and revealed in a sheet only when a person must act. |
| `GoogleAccountPassword.swift` | The Google password Ardia answers Google's check with: one keychain item (service `dev.ardia.vaults.google-account`, account = email), read only after the owner check. |
| `ChromeStoreWatcher.swift` | Polls Chrome's account store after a save and refetches the list when the new login syncs down, which also reconciles the pending save. |
| `VaultCommand.swift`, `VaultCommandResult.swift` | The hardened process runner. |
| `VaultBinaryLocator.swift` | Where binaries may live, and the ownership and permission check. |
| `VaultSessionStore.swift`, `VaultKeychain.swift`, `VaultOwnerCheck.swift` | Sessions in memory, the optional Touch ID copy, the idle clock, scratch values and preferences per provider, and the running long command (Proton's browser sign-in). |
| `VaultAutoLock.swift` | Locks every manager on sleep, screen lock and fast user switch (and keeps every background refresh quiet until wake or unlock), checks the idle timeout every minute, and refreshes stale lists when Ardia becomes active after 5 minutes away. |
| `VaultOriginMatch.swift` | Pure origin matching (no state, Foundation only). |
| `VaultPendingItems.swift` | Pure, tested with `swift test`: saves a manager's list doesn't show yet (`VaultPendingSave`), how a fresh list reconciles them (same id, or same host and username with the saved password), the logins they hide, and their 24 h expiry. |
| `VaultClipboard.swift`, `VaultPasswordGenerator.swift`, `VaultTotp.swift` | Concealed clipboard copy, strong passwords, one-time code timing. |
| `VaultJSON.swift`, `VaultMessages.swift` | Defensive JSON reading and error text cleanup shared by every provider. |
| `Vault*.swift` value types | `VaultProviderState`, `VaultItem`, `VaultSignInResult` and friends: Codable mirrors of the TS types in `packages/ardiacore/src/vaults.ts`. |

### State

Each manager reports one of `notInstalled`, `signedOut`, `locked`, `unlocked`, `unavailable`. "Unlocked" is Ardia's
own gate on top of the CLI: a manager is unlocked only while the session store holds a session for it.

- Bitwarden: the session is the real `BW_SESSION` key from `bw unlock`.
- 1Password: the session is a marker set after the 1Password app approved a call (Touch ID in 1Password).
- Proton Pass: the session is a marker set after a sign-in, or after the Mac owner check on unlock.
- Google Password Manager, web (a Google password is saved in Ardia): `locked` until unlock passes the owner check
  and reads that password, which becomes the session (`web:` + password, memory only, never the Touch ID copy), then
  `unlocked`. `account` is the Google email; `refreshedAt` (ms) is the last successful export and `hold` the error
  code that stopped automatic refreshes, with its line in `message`. Lock forgets the session and the list in memory;
  sign out forgets the Google password, the kept `rapt`, the limits and the local copy.
- Google Password Manager, Chrome source: `signedOut` when the chosen Chrome profile has no Google account (`user_name`
  in `Local State`) and no on-device `Login Data`, or has neither login store (a profile without an account still
  fills its on-device logins, with no `account`); otherwise `locked` until the session holds the AES key derived from
  Chrome's Safe Storage secret, then `unlocked`. `account` is the profile's Google email and `server` its Chrome name.
  The profile is the one picked with `vaults.configure {provider: "google", server: "<profile directory>"}` (a profile
  with neither an account nor on-device logins is refused; an empty server goes back to automatic), else the last used profile if it has an
  account, else the first that does. `vaults.googleProfiles` lists them for the picker. Sign out has nothing to tell
  Chrome: it forgets the key, the Touch ID copy, the local copy and the profile choice.

Lock forgets the session; sign out also tells the CLI to log out. When a CLI reports that the vault is locked or signed
out, the broker drops the session and the cached items and publishes the new state.

`syncing` is true while that manager's list is being fetched for any reason (unlock, a refresh on use, the schedule,
Sync Now, a Google export, a Google import in flight, a fill that has to read Google). It turns on only after the work
has run 150 ms, so a refresh answered from the cache never flickers, and turns off as soon as the last piece of work
ends; lock, sign out and any state other than `unlocked` clear it at once. Each flip is a `vaults.changed`.

### Saves show at once

A save never waits for the manager's list. The saved login goes straight into the broker's list as a pending item
(`VaultItem.pending: true`) with its password in memory, so fill and copy work on it immediately, and
`vaults.itemsChanged` fires.

- CLI managers: after the CLI's create succeeds, its item is inserted and a background refresh starts.
- Google, web: once the save passes its immediate checks (unlocked, secure origin, a password, the Google password
  saved) it answers `{saved: true, item, importId}` and the import runs in the background, using the Google password
  the unlock already read (no second owner check). Its end still comes as `vaults.googleImport` with that id; a
  `failed` end (cancelled included) removes the pending item, and the page keeps the captured login again so the offer
  can retry. Google, Chrome source: the same instant pending item and background import (with the Google password
  when the session holds it); once the import is saved, `ChromeStoreWatcher` polls Chrome's account store and the
  pending item is reconciled the moment the login syncs down, with no export.
- A pending item stops being pending when a fresh list has the same id, or a login with the same host (ignoring case
  and `www.`) and username (ignoring case) whose password is the saved one; the listed item then replaces it, and
  keeps the saved password if the list has none. Until then it hides a listed login with the same host and username
  (the old password of an update). A pending save never reconciled is dropped after 24 hours.
- Pending saves are kept in the encrypted local copy (`pending`, without passwords when Load Passwords When Used is
  on), so a relaunch or a lock and unlock keeps them. Lock forgets them in memory; sign out deletes them.

### The local copy

`VaultCache.swift` keeps one AES-GCM sealed file per manager in `<data dir>/Password Managers/Cache/<id>.vault` (0600,
excluded from backups), with a random 256-bit key in the login keychain (`vault-cache-key`; the test sandbox's file in
a hidden instance). Each file is bound to the manager's account and server and is read only while that manager is
unlocked, so it never fills anything a locked or signed-out manager wouldn't. It holds the item list and, unless
Load Passwords When Used is on, passwords:

- After an unlock the list comes from the file at once; a list older than 60 s is refreshed in the background
  (stale while revalidate) and the file rewritten. Only a manager with no copy at all waits for its CLI.
- Bitwarden's `list items` and Google's store read already carry each password, so every password is cached with no
  extra call. Other managers cache a password the first time it is fetched.
- A cached password is used only while its item's `updatedAt` is unchanged; a changed or deleted item drops it.
- Sign out (or the CLI reporting signed out) deletes the file; lock keeps it. Load Passwords When Used
  (`vaultLoadPasswordsWhenUsed`, off by default) strips every stored password and fetches each one from the CLI when it
  is used.

Sync Passwords (`vaultSyncInterval`, sent as `syncIntervalSeconds` in `vaults.setOptions`) sets how stale a list may
get (`VaultSyncSchedule`). Automatically (the default, `null`) is the 60 s refresh on use above. Every 5 Minutes, Every
15 Minutes and Every Hour (300, 900, 3600) use that interval on use, and the idle-lock tick (every minute) also
refreshes each unlocked manager whose list is older, one at a time per manager through its lane and never a locked one;
these refreshes don't count as use for the idle lock. Bitwarden runs `bw sync` at most every 5 minutes, so a timed
refresh always syncs. Manually (0) never refreshes in the background: lists come from the cache or the local copy
until Sync Now (Settings › Passwords, the Sync Passwords row for every unlocked manager or a manager's ⋯ menu), which
calls `vaults.refresh` and then lists again.

`vaults.providers` answers at once from the cached states (or a placeholder: `notInstalled` when no binary is found,
otherwise `locked`) and starts one background refresh, which emits `vaults.changed` for each state that differs.

## Security model

1. **Secrets stay native.** Passwords, saved form passwords, master passwords, API keys and session keys never reach
   JS, an event payload or a log. JS sees item metadata (id, title, username, urls, hasTotp, vault name) and one-time
   codes. Error text from a CLI is reduced to its first line, stripped of log prefixes, capped at 240 characters, and
   any secret Ardia passed to that command is replaced with `[hidden]`.
2. **Fill checks.** `VaultBroker.fillValues` refuses unless the origin is https (or http on localhost, 127.0.0.1 or
   ::1), the manager is unlocked, the item exists in a fresh list, and one of the item's URLs matches the origin
   (`VaultOriginMatch`: same host, or one host is a dot-suffix subdomain of the other; IP addresses match exactly; a
   single-label host never matches by suffix; a registry suffix such as `co.uk` or a shared-hosting suffix such as
   `github.io` never matches by suffix, and a host under shared hosting matches only exactly; an explicit port in the
   saved URL must equal the page's port; the JS ranking in `state/vaults/originMatch.ts` uses the same lists). The
   person choosing an item from search (`userChose`) skips only the URL match, never the https rule. The origin
   comes from the native VerifiedOrigin of the frame, and the page script checks `location.origin` again at fill time.
3. **Binaries.** Only fixed locations are searched (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`,
   `~/.npm-global/bin`, `/opt/local/bin`, `~/bin`). The path, its directory, the resolved target and the target's
   directory must be owned by root or the current user and not be world-writable, and the target must be a regular
   executable file. Commands never go through a shell.
4. **Processes.** Each run gets an explicit environment: `HOME`, `USER`, `LOGNAME`, `TMPDIR`, proxy and CA variables
   when set, `LANG=en_US.UTF-8` (so error text is parseable), `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, then `/opt/homebrew/bin` and `/usr/local/bin` when they pass the
   locator's directory checks (so an npm-installed `bw` finds `node`), then the binary's own directory, and the
   provider's variables. Stdin is `/dev/null`, or a pipe that is written and closed (with
   `SIGPIPE` off for that descriptor). Stdout and stderr drain concurrently; stdout is capped at 32 MB (the process
   is stopped past it) and stderr at 1 MB. Every call has a timeout: terminate, then `SIGKILL` 2 s later. Flags take
   their values in `--flag=value` form so an id or title can't be read as an option, and ids are validated before
   they reach argv.
5. **Secrets in argv: never.** Master passwords go through `bw --passwordenv` in that one process's environment, API
   keys through `BW_CLIENTID`/`BW_CLIENTSECRET`, Proton tokens through `PROTON_PASS_PERSONAL_ACCESS_TOKEN`, and new
   logins as JSON (or base64 JSON for `bw`) on stdin. The one exception is a Bitwarden two-step code, which `bw` takes
   only as `--code`; it is short-lived.
6. **One call at a time per manager.** Every CLI call runs inside that manager's `VaultLane`, so two callers never
   race the same CLI (or invalidate each other's `bw` session). Concurrent item list requests share one fetch.
7. **Touch ID copy (Bitwarden).** With the Touch ID option on, the session key is also written to the login keychain
   (service "Ardia Password Managers", `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` where accepted). Reading it back
   first passes `LAContext` (biometrics, falling back to the Mac password), and the key is checked with `bw status`
   before use. Any keychain failure degrades to memory only. This path needs no entitlement, so it works in ad-hoc
   and development signed builds. Turning the option off deletes every stored copy, and lock then also runs `bw lock`.
8. **Google Password Manager.** Unlock reads Chrome's "Chrome Safe Storage" keychain item. When macOS answers
   without asking (the person once chose Always Allow), the Mac owner check runs before Ardia accepts the key; when
   macOS shows its keychain prompt, that prompt is the approval. Ardia keeps only the derived 128-bit key (PBKDF2-SHA1,
   "saltysalt", 1003 rounds), as the session in memory and, with the Touch ID option on, as the keychain copy above.
   The raw secret is only a local value while the key is derived; Ardia doesn't zero it (Swift's `Data` gives no
   guarantee), it just never stores or passes it on. The key is checked against the profile's rows before it is accepted, and a
   key that opens none of them locks the manager. Chrome's databases are never read in place. While Chrome has a database
   open (its `-wal` and `-shm` both exist), Ardia opens it read-only and copies it with SQLite's online backup into a
   fresh 0700 temporary folder, which gives a consistent snapshot. Otherwise (Chrome closed, files stable) it copies the
   file and its `-wal`/`-journal` and checks that their size and change time didn't move during the copy. Either way
   it reads the private copy and deletes the folder, and retries once when the snapshot caught Chrome mid-write.
   Opening a closed Chrome's database read-only would create a `-shm` file next to it, which is why that case copies
   instead. Copies left by a crash (`ardia-chrome-*` older than 10 minutes) are removed once per launch. Ardia never writes to Chrome's databases (rows without Chrome's sync
   metadata would never upload anyway). Rows Chrome never fills on a web page are left out: never-save entries,
   federated sign-ins, empty passwords and non-web (Android) logins. A login in both stores is listed once, from the
   Google Account. Item ids are `account.` or `device.` plus 32 hex digits of SHA-256 over the store, origin, username
   and realm, and are validated before use.
9. **Reading from Google.** Google has no API for listing passwords either, so Ardia runs passwords.google.com's own
   export in the same hidden page (`GoogleWebImporter.export`, the provider's `itemsAndPasswords`):
   1. `ArdiaHiddenPage` opens `/options` (with the kept `rapt`, below) and its config says `csvExport: true` with the
      passwords origin. Only then, and only when the top frame's own origin is that origin, the page script replaces
      `window.Blob` with a proxy that hands any `text/csv` Blob built from strings to native (`csvExport`), and makes
      download links (`a[download]`, `blob:` and `data:` links, their clicks, `window.open` of a blob) do nothing. Every
      other tab keeps the real `Blob`. Native also cancels and removes any download whose URL is `blob:` of that origin
      (or `data:text/csv`) while such a page is open, deleting a finished file (`blockDownloads(from:)`). Nothing
      reaches Downloads or the data folder; the text lives only in memory and in the encrypted local copy below.
   2. The visible icon button with `aria-label="Export"` renders a moment after load; Ardia clicks it, then the
      visible Export of the "Export Passwords" dialog (Cancel, Export), answers the password check like an import,
      and clicks Export again if Google comes back to `/options` without the file (at most 3 clicks each, 4 s apart).
      `GoogleExportFlow` has the same 20 s step and 60 s overall limits, and 5 minutes once a person is needed.
   3. Google builds the file with `new Blob([csv], {type: "text/csv;charset=utf-8;"})`, header
      `name,url,username,password,note`. `GoogleExportCSV` parses quoted fields (commas, `""`, newlines in notes, a
      byte order mark, any column order), keeps http(s) rows with a password, and lists each as a `Google Account`
      item with id `web.` + 32 hex of SHA-256 over the URL and username. The list feeds the broker's cache, its
      encrypted local copy and the fill path; lock drops the copy in memory.
   4. After every password check Google returns to `/options?…&rapt=<token>`. Ardia keeps the latest token in memory
      (`GoogleRapt`, only from the passwords origin, URL-safe characters only) and adds it to the next export and import
      URL; when Google asks for the password anyway, the token is dropped.

   **Rate limits** (`GoogleWebLimits`, persisted to `Password Managers/Cache/google-web-limits.json` so a relaunch
   keeps them; no secrets in it):
   - Without a fresh `rapt` (one seen in the last hour), a refresh happens only on unlock, on Sync Now (or Confirm…), or
     on the sync schedule, never because a list was used. Unlock and the schedule refresh at most once an hour after
     the last success and 15 minutes after the last attempt. Sync Now also waits an hour after the last success
     (`personSyncAgainAt`, published as `syncAgainAt`): pressed earlier, Settings shows an alert with the time it may
     run again and why, and Sync Anyway (`vaults.refresh` `anyway`, trigger `personAnyway`) skips the hour and the
     backoff but not a 60 s spacing. A failed sync doesn't start the hour, so Try Again runs. Confirm… and a fill that
     has no list yet run as `personAnyway`. A person run waits up to 90 s for saves in flight instead of answering busy.
   - With a fresh `rapt` the export needs no password check, so the schedule and using a list (also Ardia becoming
     active after 5 minutes away) may refresh an hour after the last success, still 15 minutes after the last
     attempt and outside any backoff or hold. Such a run never answers a check: if Google asks anyway it ends as
     `checkTooSoon` and the token is dropped, which puts the next run back on the hourly rule.
   - After an import is saved (Google has just handed back a fresh `rapt`), Ardia runs a reconcile export (trigger
     `afterSave`) 10 s after the import queue empties, at least 60 s after the previous export, never answering a check;
     while a pending save is still missing it tries again a minute later, at most 3 more times.
   - An automatic run answers at most one password check per 10 minutes (counting imports): with no fresh `rapt` it
     doesn't start, and a check met mid-run ends it as `checkTooSoon` without typing the password. Sync Now may answer.
   - After a failure automatic runs back off 15 minutes, then 30, doubling up to 6 hours; a success clears it.
     Cancelled, refused (`notAllowed`) and `checkTooSoon` runs aren't failures.
   - Any page other than the plain password check (sign in, 2-Step Verification, captcha, unusual activity, insecure
     browser, on-device encryption) stops all automatic runs (`hold`) until the person presses Confirm… on the row
     (Sync Now), which clears the hold and runs by the person; a person-run that meets such a page reveals it in a
     sheet (`vaults.googleExport` `confirm`).
   - One hidden-page operation at a time: an export doesn't start while an import, another export or the sign-in
     check runs, and imports wait for an export. A sign-in check page left on Google's sign-in (`googleSignIn` said
     `signIn`) closes after 2 minutes unless it was revealed, so it can't block exports.
   - Lock cancels a running export and drops a list that arrives after it; sign out also cancels every queued and
     running import (`failed`, `cancelled`).
   A refused or failed run keeps the last list (memory, else the encrypted local copy). With "Load passwords when
   used" on and no list in memory, a fill runs a person export.
10. **Saving to Google.** Google has no API for adding a password, so Ardia uses passwords.google.com's own import,
   driven in a page nobody sees (`GoogleWebImporter`). Setup asks for two things: that Google is signed in inside Ardia's
   default profile (`vaults.googleSignIn` loads passwords.google.com hidden and says `signedIn` or `signIn`; Sign In…
   reveals Google's sign-in page in a sheet), and the Google password (`saveGooglePassword(email, password)`, a secret
   function like `unlock`), kept as one keychain item, service `dev.ardia.vaults.google-account`, account = the email,
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Reading it back always passes the owner check first (Touch ID or
   the Mac password); it is never logged, never in an event and never in JS; it goes only to the challenge page through
   the page script. The row's ⋯ menu has Save/Update Google Password… and Forget Google Password; Disconnect forgets it too.
   A save (`VaultBroker.saveToGoogle`, outside the provider's lane so fills never wait on it) queues one import at a time,
   and an identical pending save (same URL, username and password) joins the one in flight. The import:
   1. `ArdiaHiddenPage` opens `https://passwords.google.com/options?import=1` (with the kept `rapt`) in a Chrome tab of the default profile, so
      it has the person's Google cookies. The tab lives in a stray `ArdiaWindowController`'s window, which is never
      ordered in, and its view is parked in an off-screen view: nothing on screen, nothing in the Window menu or
      Mission Control, no activation. The engine needed no change.
   2. Every 300 ms Ardia snapshots the page (main world, `evaluate`: URL, text, the visible dialog and its visible
      buttons, password field, captcha, spinner) and `GoogleImportClassifier` names the step; `GoogleImportFlow` picks
      the action. The selectors and texts are one table, `GoogleImportSelectors` and `GoogleImportText`.
   3. On `accounts.google.com/v3/signin/challenge/pwd` ("To continue, first verify it's you") it fills the stored
      password through the page script (`fileImportFill`, which checks the page's origin, sets the field, fires input
      and change and clicks Next). Google asks on every import. A rejected password (`aria-invalid` or Google's
      wrong-password text) fails at once; an ignored submit is retried once after 10 s, never more.
   4. Back on `/options?import=1&rapt=…` the page opens its file chooser by itself. The page script, which runs in the
      main world at document start in every frame, wraps `HTMLInputElement.prototype.click` and `showPicker` for
      `type=file`, `window.showOpenFilePicker`, and catches clicks on file inputs. A top frame holds such a call until
      its config arrives (at most 1.5 s, then the call goes through as before); only the hidden page's config says
      `fileImport: true`, so in every other tab the call proceeds unchanged. In the hidden page the call never reaches
      the browser: the page script asks native (`fileChooser`), native checks the frame's verified origin is
      passwords.google.com, and answers with the one-row CSV (`name,url,username,password,note`, every field quoted,
      built in memory, never on disk) as `Ardia.csv`; the page script puts it in the input through a `DataTransfer` and
      fires input and change. If no chooser came 2 s into the import dialog, Ardia presses Select file.
   5. Ardia presses the dialog's visible Import, reads "N password(s) imported", presses Done and answers `saved`.
   There is a 20 s limit per step and 60 s overall. Google's pages that only a person can pass (sign in, 2-Step
   Verification, captcha) answer the save `code: "confirm"` with an `importId`; the offer says "Google needs you to
   confirm" with Confirm…, which calls `vaults.googleReveal {id}` and shows the same page in a sheet. The import keeps
   running (5 minutes from then), and its end comes as `vaults.googleImport` `saved` or `failed`. Cancel in the sheet
   cancels the import. With the Chrome source, after a save the store watcher polls Chrome's account store (every 2 s,
   10 minutes) and refetches the list when the login syncs down; with the web provider the reconcile export above does
   that.
   Error codes, each with one line: `noPassword`, `wrongPassword` (both offer Update Password…), `signIn`, `twoStep`,
   `captcha` (Confirm…), `insecureBrowser`, `onDeviceEncryption` (only when the import dialog asks for the on-device
   encryption PIN or unlock; the row on the options page doesn't count), `pageChanged`, `network`, `timeout`,
   `importFailed`, `cancelled`, `notAllowed` (owner check refused), `unavailable` (no engine or profile yet), and for
   reading also `unusualActivity` (Confirm…) and `checkTooSoon`.
11. **Auto-lock.** After the idle timeout (default 30 minutes without a list, fill, copy, code or save), and on sleep,
   screen lock or fast user switch, every manager locks and `vaults.changed` is emitted. Sleep, screen lock and fast
   user switch also wipe every tab's captured logins (`ArdiaVaultCapture wipeAll`).
12. **Owner check before passwords.** With Ask Before Filling on (the default, `vaultAskBeforeFilling`, sent as
   `askBeforeFilling` in `vaults.setOptions`), `VaultBroker.fillValues` refuses any fill that includes a password, and
   `copy` refuses a password copy, until the Mac owner confirms with Touch ID or the login password
   (`VaultOwnerCheck`). A refused fill answers `notAuthorized` and the menu stays open with no error; a refused copy
   answers `declined` and shows no toast. Usernames and one-time codes don't ask. The fill menu also shows Apple's
   embedded Touch ID view (`VaultTouchIDView`, `LAAuthenticationView`) on the selected login, or the first one: a
   touch on the sensor grants the broker one owner check for 10 s (`grantOwner`) and emits `vaults.touchID`; JS fills
   the row it armed (`state/vaults/touchID.ts`), with no dialog. Apple's glyph is drawn transparent and the row shows
   the `touchid` symbol in its own text colour instead. Without Touch ID, or after a lockout, Return or a click asks through the system prompt instead.
   `vaults.biometrics` says whether Touch ID can be used.
12. **Clipboard.** Copies are marked `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType`, and the
   pasteboard is cleared after 90 s if nothing else was copied since.
13. **Test instances.** In a hidden test instance (`ARDIA_BACKGROUND=1` with `ARDIA_DATA_DIR`, `VaultSandbox`), binaries are looked up only in `<data dir>/Password Managers/bin`,
    each CLI gets its own state folder under `<data dir>/Password Managers/<id>` (`OP_CONFIG_DIR`,
    `BITWARDENCLI_APPDATA_DIR`, `PROTON_PASS_SESSION_DIR` with the file key provider), and the keychain copy goes to
    `<data dir>/Password Managers.json` (0600) instead of the real keychain. Google Password Manager reads Chrome only
    from `<data dir>/Password Managers/google/Chrome` (a copy of `packages/ardiacore/tests/fixtures/google/Chrome`, built
    by `pnpm -C packages/ardiacore fixtures:google`); Chrome counts as installed only when that folder has a `Local
    State`, and the Safe Storage secret comes from the `google-safe-storage` entry of `Password Managers.json`, never
    the keychain. The Google password is kept in `<data dir>/Password Managers/google/account.json` (0600) instead of the
    keychain, and `ARDIA_TEST googlePasswordsURL=<origin>,googleAccountsURL=<origin>` points the hidden import and
    export at a local fixture (both are needed; anything else uses Google): `python3
    packages/ardiacore/tests/fixtures/google-web/server.py <port> <log.jsonl>` serves the options page with Import and
    the delayed Export button and dialog, the password check (fresh `rapt` per accepted check, valid
    `FIXTURE_RAPT_SECONDS`), the import dialog, and a Blob-built CSV that the page also tries to download; rows
    imported into it show in later exports. One owner-approved
    override exists for end-to-end runs: `ARDIA_TEST googleChromeAccount=<email>` (background mode only, and like every
    `ARDIA_TEST` value ignored outside a test instance) points the provider at the real Chrome folder but only at the
    profile whose `user_name` is that email (no match is `signedOut`; no other profile is listed or read), reads the
    real Safe Storage item (its prompt shows on the owner's screen) and keeps the derived key in memory only. Everything
    else stays sandboxed. In background mode the owner check never
    prompts (it answers from `ARDIA_TEST=reauth=granted`) and the Touch ID view draws its glyph without arming, copies go to a private pasteboard, and sleep or screen lock
    of the owner's Mac doesn't lock the test's vaults.

### Known limits

- Bitwarden items with master password re-prompt are left out of the list, because the CLI can't honour re-prompt.
- Bitwarden's new-device email code has no CLI flag; the sign-in error suggests the personal API key instead.
- A Proton Pass session lock can only be lifted with `pass-cli session unlock` in Terminal.
- 1Password's list has no one-time code flag, so `hasTotp` is unknown there and `vaults.totp` answers `null` when the
  item has none.
- Google Password Manager reads the account's passwords as of the last export: at most hourly by itself or on Sync
  Now, plus the reconcile after a save and Sync Anyway. How long Google honours a `rapt` isn't published;
  Ardia counts one as fresh for an hour and drops it the first time Google asks for the password anyway. Passkeys, notes and Android app logins aren't read. The export flow follows passwords.google.com as measured
  in November 2026; a change fails as `pageChanged` until `GoogleImportSelectors` is updated.
- On the Chrome source a save still goes through passwords.google.com as Ardia's default profile is signed in. When
  that is a different Google Account from Chrome's profile, the login lands in that other account, Chrome's store
  never gets it, and the pending item is dropped after 24 hours.
- Saving to Google needs Google signed in inside Ardia's default profile and the Google password saved in Ardia; a
  Google Account with on-device encryption, or one that asks for 2-Step Verification on every import, needs the person
  each time. The flow follows passwords.google.com's page as measured in November 2026; a change there fails as
  `pageChanged` until `GoogleImportSelectors` is updated.
- Origin matching uses a short built-in suffix list, not the full public suffix list: a registry suffix missing from it
  (and not of the `co.xx` form) could match its subdomains.

## The JS surface

Calls (`call("vaults.<name>", args)`, typed in `packages/ardiacore/src/engine/api.ts`):

| Call | Args | Returns |
| --- | --- | --- |
| `providers` | `{}` | `VaultProviderState[]` |
| `refresh` | `{provider}` | `VaultProviderState` (drops the item cache, keeping pending saves, forces a Bitwarden sync next list) |
| `items` | `{provider?}` | `VaultItem[]` (empty for a locked manager; pending saves carry `pending: true`) |
| `lock`, `signOut`, `cancelSignIn` | `{provider}` | `VaultProviderState` |
| `configure` | `{provider, server?}` | `VaultProviderState` (`message` says why a change was refused) |
| `copy` | `{provider, id, field: "username" \| "password" \| "totp"}` | `{copied, clearsAfter}` |
| `totp` | `{provider, id}` | `{code, period, expiresAt} \| null` |
| `generate` | `{}` | `{length}` |
| `googleProfiles` | `{}` | `{directory, name, email \| null, selected}[]` (Chrome profiles with a folder on disk) |
| `googleAccount` | `{}` | `{email \| null, hasPassword}` (no owner check: the password isn't read) |
| `googleSource` | `{choice: "automatic" \| "chrome" \| "web"}` | `VaultProviderState` (locked when the session can't serve the new source) |
| `forgetGooglePassword` | `{}` | `{email, hasPassword}` |
| `googleSignIn` | `{}` | `{state: "signedIn" \| "signIn" \| "insecureBrowser" \| "network" \| "unavailable"}` |
| `googleReveal` | `{id?}` | `{revealed}` (the import's page, or Google's sign-in page without an id) |
| `setOptions` | `{idleLockMinutes, touchID, askBeforeFilling, loadPasswordsWhenUsed, syncIntervalSeconds}` | `{}` |

Secret functions (`packages/ardiacore/src/vaults.ts`): `signInToVault(provider, fields)` and
`unlockVault(provider, password | null)`, both resolving to a `VaultSignInResult`. Sign-in fields per manager:

- 1Password: `{account?}`. There is no password; the 1Password app approves with Touch ID.
- Bitwarden: `{server?, email, password, method?, code?}` or `{server?, clientId, clientSecret, password?}`. A result
  with `needs: "code"` and `methods` asks the person to pick a method (`"0"` authenticator, `"1"` email,
  `"3"` YubiKey) and send it back as `method`; choosing email sends the email and asks for the code.
- Proton Pass: `{password?}` starts the browser sign-in; the result has `needs: "approval"` and `approvalURL` to open
  in a tab, and `vaults.changed` follows when the CLI finishes. `{method: "accessToken", clientSecret: token,
  password?}` signs in with a personal access token. `password` is the optional extra Pass password.

`unlockVault(provider, null)` means Touch ID: the Bitwarden keychain copy, 1Password's app, or the Mac owner check
for Proton Pass.

`unlockVault("google", null)` and `signInToVault("google", {})` read the saved Google password after the owner check
(the Chrome source reads Chrome's key instead); the setup kind is `chrome` and the row's Connect… opens the Google
sheet (sign in to Google in Ardia, then the Google password; Connect saves it and unlocks). A save to Google with the Google
password saved answers at once `{saved: true, item, importId}` with `item.pending: true`; the import's `confirm`,
`saved` or `failed` follows as `vaults.googleImport` with `id = importId` (a `failed` `wrongPassword` or `noPassword`
means Update Password…). A save that fails its immediate checks answers as before:
`{saved: true, item}`, `{saved: false, code: "confirm", importId, reason, error}` while Google needs the person, or
`{saved: false, code, error, action?}` with one of the error codes above (`action: "updatePassword"` for `noPassword`
and `wrongPassword`). A CLI manager's save answers `{saved: true, item}` with `item.pending: true`.
`saveGooglePassword(email, password)` resolves to `{ok, error}`.

`VaultProviderState.syncing` is true while the manager's list is being fetched (see State).

Events: `vaults.changed` `{provider: VaultProviderState}`, `vaults.itemsChanged` `{provider}`, `vaults.googleImport`
`{provider, id, state: "confirm" | "saved" | "failed", host, code?, message?}`, `vaults.googleExport` `{provider, id,
state: "confirm" | "saved" | "failed", trigger: "unlock" | "schedule" | "person" | "use" | "afterSave", code?, message?}` and `vaults.googleSignIn` `{provider,
signedIn}` (the revealed sign-in page reached passwords.google.com).

## Adding a password manager

A new manager is one Swift file, one registry line and one row in the JS brand table.

1. **Learn the CLI.** Find where it installs, how it reports signed in and locked, which commands list logins and
   fetch one secret, how it creates a login, and which commands can wait for a person (a prompt, a browser, Touch ID).
   Find a way to pass every secret through the environment or stdin.
2. **Create `packages/ardiacore/ios/<Name>Vault.swift`** with a struct that conforms to `VaultProvider`. Keep it
   stateless: anything a manager needs to remember goes through `VaultCLI` (`remember(session:)`, `value`/`setValue`
   for values that last until the next refresh or lock, `preference`/`setPreference` for values that last until sign
   out).
3. **Map errors with `checked`.** Give it the lowercase substrings that mean locked, signed out and not found;
   everything else becomes a cleaned, redacted failure message.
4. **Parse defensively** with `VaultJSON` (missing fields, numbers as strings, dates in any of the common forms) and
   build `VaultItem`s with metadata only. Drop secret fields as soon as you've read what you need.
5. **Add it to `VaultRegistry.providers`.**
6. **Add its brand row in the JS table** (name, icon) next to the existing three.
7. **For test instances**, return the CLI's state-folder variable from `isolatedEnvironment(_:)` so a hidden instance
   never touches the person's real session.
8. **A manager with no binary** (an app's data, like Google Password Manager) implements `locate()` returning
   `.dataFolder(path)` (nil when the app isn't installed) and `notInstalledMessage`; `cli.dataFolder` is then its path
   and `cli.run` never launches anything. Leave `binaryName` empty. In a test instance, read the app's data only from a
   fixture under `<data dir>/Password Managers/<id>`.

```swift
import Foundation

struct ExampleVault: VaultProvider {
  let id = "example"
  let name = "Example"
  let binaryName = "example-cli"
  let capabilities = VaultCapabilities(totp: true, save: false, selfHosted: false, masterPassword: true, touchID: false)
  let install = VaultInstall(command: "brew install example-cli", url: "https://example.com/cli")
  let setup: VaultSetup? = VaultSetup(kind: .credentials)

  private static let tool = "Example CLI"

  func isolatedEnvironment(_ directory: String) -> [String: String] { ["EXAMPLE_CONFIG_DIR": directory] }

  func state(_ cli: VaultCLI) async -> VaultProviderState {
    let result = await cli.run(["status", "--json"])
    guard result.succeeded, let status = VaultJSON.dict(VaultJSON.parse(result.stdout)) else {
      return makeState(.unavailable, message: VaultMessages.failure(result, tool: Self.tool))
    }
    guard VaultJSON.bool(status["signedIn"]) == true else { return makeState(.signedOut) }
    return makeState(cli.session == nil ? .locked : .unlocked, account: VaultJSON.string(status["email"]))
  }

  func signIn(_ cli: VaultCLI, fields: VaultSignInFields) async -> VaultSignInResult {
    await unlock(cli, password: fields.password)
  }

  func unlock(_ cli: VaultCLI, password: String?) async -> VaultSignInResult {
    guard let password else { return needs(.password) }
    let result = await cli.run(["unlock", "--password-env", "ARDIA_EXAMPLE_PASSWORD"], environment: ["ARDIA_EXAMPLE_PASSWORD": password])
    guard result.succeeded else { return failed(VaultMessages.failure(result, tool: Self.tool, redacting: [password])) }
    cli.remember(session: result.trimmedOutput)
    return signedIn()
  }

  func signOut(_ cli: VaultCLI) async {
    _ = await cli.run(["logout"])
  }

  func items(_ cli: VaultCLI) async throws -> [VaultItem] {
    guard let session = cli.session else { throw VaultError.locked }
    let result = await cli.run(["list", "--json"], environment: ["EXAMPLE_SESSION": session], timeout: 60)
    try check(result)
    return VaultJSON.dicts(VaultJSON.parse(result.stdout)).compactMap { entry in
      guard let itemId = VaultJSON.string(entry["id"]) else { return nil }
      return VaultItem(provider: id, id: itemId, title: VaultJSON.string(entry["title"]) ?? "",
                       username: VaultJSON.string(entry["username"]) ?? "", urls: VaultJSON.strings(entry["urls"]))
    }
  }

  func secret(_ cli: VaultCLI, id: String, field: VaultField) async throws -> String {
    guard let session = cli.session else { throw VaultError.locked }
    let result = await cli.run(["get", field.rawValue, "--id=\(id)"], environment: ["EXAMPLE_SESSION": session])
    try check(result)
    guard !result.trimmedOutput.isEmpty else { throw VaultError.notFound }
    return result.trimmedOutput
  }

  private func check(_ result: VaultCommandResult) throws {
    try checked(result, tool: Self.tool, locked: ["locked"], signedOut: ["not signed in"], missing: ["not found"])
  }
}
```

Then in `VaultRegistry.swift`:

```swift
static let providers: [any VaultProvider] = [OnePasswordVault(), BitwardenVault(), ProtonPassVault(), ExampleVault()]
```

What the core already does for the new manager, so the provider must not repeat it: finding and vetting the
binary, the environment, timeouts and output caps, one call at a time, the state and item caches, `vaults.changed`
and `vaults.itemsChanged`, idle and sleep lock, origin checks before a fill, the clipboard, and dropping the session
when the CLI reports locked or signed out.

## Saved Passwords

Settings › Passwords lists Ardia's own saved passwords and the logins of every unlocked manager in one list, sorted by
site and searched together; a manager's login carries its badge. Its sheet copies the username, and copies the
password through the broker (owner check first); a manager's password never reaches JS, so it isn't shown.
