#!/usr/bin/env python3
"""Builds the Google Chrome User Data fixture that Google Password Manager's tests read.

Everything is invented. The passwords are encrypted with the fixture Safe Storage secret in
packages/import/fixtures/secrets.json, through the system openssl CLI, so the fixture is made
by code independent of the Swift decryptor it tests.

  python3 packages/ardiacore/tests/fixtures/google/generate.py [--out DIR]

Writes DIR/Chrome (default: next to this script) with Local State, Default (signed in as
test@example.com: Login Data For Account and Login Data, the latter with rows only in its WAL)
and Profile 1 (not signed in). A hidden test instance copies DIR/Chrome to
<data dir>/Password Managers/google/Chrome and puts the secret in <data dir>/Password Managers.json
under google-safe-storage.
"""

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SECRETS = os.path.join(HERE, "..", "..", "..", "..", "import", "fixtures", "secrets.json")
BASE_UNIX = 1788220800

LOGINS_SCHEMA = """
CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR, username_value VARCHAR,
  password_element VARCHAR, password_value BLOB, submit_element VARCHAR, signon_realm VARCHAR NOT NULL,
  date_created INTEGER NOT NULL, blacklisted_by_user INTEGER NOT NULL, scheme INTEGER NOT NULL, password_type INTEGER,
  times_used INTEGER, form_data BLOB, display_name VARCHAR, icon_url VARCHAR, federation_url VARCHAR,
  skip_zero_click INTEGER, generation_upload_status INTEGER, possible_username_pairs BLOB,
  id INTEGER PRIMARY KEY AUTOINCREMENT, date_last_used INTEGER NOT NULL DEFAULT 0, moving_blocked_for BLOB,
  date_password_modified INTEGER NOT NULL DEFAULT 0, sender_email VARCHAR, sender_name VARCHAR, date_received INTEGER,
  sharing_notification_displayed INTEGER NOT NULL DEFAULT 0, keychain_identifier BLOB, sender_profile_image_url VARCHAR,
  date_last_filled INTEGER NOT NULL DEFAULT 0, actor_login_approved INTEGER NOT NULL DEFAULT 0,
  UNIQUE (origin_url, username_element, username_value, password_element, signon_realm));
INSERT INTO meta VALUES ('version', '43');
"""


def chrome_time(unix_seconds):
    return int((unix_seconds + 11644473600) * 1_000_000)


def derive(secret):
    return hashlib.pbkdf2_hmac("sha1", secret, b"saltysalt", 1003, 16)


def v10(plain, key):
    args = ["openssl", "enc", "-aes-128-cbc", "-K", key.hex(), "-iv", (b" " * 16).hex()]
    return b"v10" + subprocess.run(args, input=plain, capture_output=True, check=True).stdout


def insert(db, origin, realm, user, blob, blacklisted=0, federation=None, modified_days=10):
    db.execute(
        """INSERT INTO logins(origin_url, action_url, username_element, username_value, password_element, password_value,
           signon_realm, date_created, blacklisted_by_user, scheme, times_used, federation_url, date_last_used,
           date_password_modified) VALUES (?,?,?,?,?,?,?,?,?,0,1,?,?,?)""",
        (origin, origin, "email", user, "password", blob, realm, chrome_time(BASE_UNIX - 86400 * 30), blacklisted,
         federation, chrome_time(BASE_UNIX - 3600), chrome_time(BASE_UNIX - 86400 * modified_days) if modified_days else 0))


def account_rows(key, wrong):
    return [
        ("https://github.com/login", "https://github.com/", "octo@example.com", v10(b"gh-fixture-pass", key)),
        ("https://accounts.google.com/signin", "https://accounts.google.com/", "test@example.com", v10(b"google-fixture-pass", key)),
        ("http://localhost:3000/login", "http://localhost:3000/", "dev", v10(b"localhost-fixture-pass", key)),
        ("https://www.shop.example/", "https://www.shop.example/", "alex", v10("pässwörd 🔑".encode(), key)),
        ("https://never.example/", "https://never.example/", "", b"", 1),
        ("https://empty.example/", "https://empty.example/", "nobody", v10(b"", key)),
        ("https://fed.example/", "https://fed.example/", "fed@example.com", b"", 0, "https://accounts.google.com"),
        ("android://hash@com.example.app/", "android://hash@com.example.app/", "alex", v10(b"from-android", key)),
        ("https://wrongkey.example/", "https://wrongkey.example/", "bob", v10(b"secret", wrong)),
    ]


def device_rows(key):
    return [
        ("https://local.example/signin", "https://local.example/", "mac-only", v10(b"local-fixture-pass", key)),
        ("https://127.0.0.1:8443/", "https://127.0.0.1:8443/", "router", v10(b"router-fixture-pass", key)),
        ("https://github.com/login", "https://github.com/", "octo@example.com", v10(b"stale-device-copy", key)),
    ]


def write_db(path, rows, wal_only=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for suffix in ("", "-wal", "-shm", "-journal"):
        if os.path.exists(path + suffix):
            os.remove(path + suffix)
    if not wal_only:
        db = sqlite3.connect(path)
        db.executescript(LOGINS_SCHEMA)
        for row in rows:
            insert(db, *row)
        db.commit()
        db.close()
        return
    with tempfile.TemporaryDirectory() as scratch:
        staged = os.path.join(scratch, "db")
        db = sqlite3.connect(staged)
        db.executescript(LOGINS_SCHEMA)
        db.commit()
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA wal_autocheckpoint=0")
        for row in rows:
            insert(db, *row)
        db.commit()
        shutil.copyfile(staged, path)
        shutil.copyfile(staged + "-wal", path + "-wal")
        db.close()


def build(out):
    with open(SECRETS) as handle:
        secret = json.load(handle)["chromiumSafeStorageSecret"].encode()
    key = derive(secret)
    wrong = derive(b"some-other-secret")
    root = os.path.join(out, "Chrome")
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(os.path.join(root, "Profile 1"))
    with open(os.path.join(root, "Local State"), "w") as handle:
        json.dump({"profile": {
            "info_cache": {
                "Default": {"name": "Person 1", "user_name": "test@example.com", "gaia_name": "Test User"},
                "Profile 1": {"name": "Work", "user_name": "", "gaia_name": ""},
            },
            "last_used": "Default",
            "profiles_order": ["Default", "Profile 1"],
        }}, handle, indent=2)
    with open(os.path.join(root, "Profile 1", "Preferences"), "w") as handle:
        json.dump({"profile": {"name": "Work"}}, handle)
    write_db(os.path.join(root, "Default", "Login Data For Account"), account_rows(key, wrong))
    write_db(os.path.join(root, "Default", "Login Data"), device_rows(key), wal_only=True)
    return root, secret.decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=HERE)
    args = parser.parse_args()
    root, _ = build(os.path.abspath(args.out))
    print(root)


if __name__ == "__main__":
    main()
