import Foundation

/// Builds the "break-glass" disaster-recovery script: a single self-contained
/// Python file with the bucket credentials and (if held) the age secret baked
/// in. Save that one file somewhere safe and a laptop can rebuild the whole
/// photo archive with `python3 restore.py` — no SnapSiphon, no SDKs.
///
/// ⚠️ The full export contains live secrets in plaintext — the UI gates it
/// behind Face ID and tells the user to store it like a password (it *is*
/// one). The secrets-free export prompts for them at run time instead.
///
/// Runtime needs: python3 ≥3.8 (stdlib SigV4 + sqlite3), plus ONE decryption
/// backend: the `age` CLI (preferred) or `pip3 install cryptography` (a
/// pure-Python age-v1 decryptor is embedded).
enum RestoreScript {
    /// `includeSecrets: false` leaves SECRET_KEY and AGE_SECRET empty — the
    /// script's startup config review highlights them as missing and prompts
    /// (hidden input) at run time, so the exported file is safe-ish to store
    /// anywhere the bucket name is acceptable.
    /// Escape a value for embedding inside a double-quoted Python string
    /// literal — config values are user-controlled text and must never be able
    /// to break out of the assignment.
    private static func pyString(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 { out += String(format: "\\x%02x", c.value) }
                else { out.unicodeScalars.append(c) }
            }
        }
        return out
    }

    static func build(config: S3Config, credentials: S3Credentials, ageSecret: String?,
                      includeSecrets: Bool = true) -> String {
        let secret = pyString(includeSecrets ? (ageSecret ?? "") : "")
        let secretKey = pyString(includeSecrets ? credentials.secretAccessKey : "")
        let sessionToken = pyString(includeSecrets ? (credentials.sessionToken ?? "") : "")
        let endpoint = pyString(config.endpoint)
        let region = pyString(config.region)
        let bucket = pyString(config.bucket)
        let accessKey = pyString(credentials.accessKeyID)
        let prefix = pyString(config.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))
        let pathStyle = config.usesPathStyle ? "True" : "False"
        return #"""
#!/usr/bin/env python3
"""SnapSiphon disaster-recovery restore.

Reads the repository's newest checkpoint (an encrypted SQLite snapshot) and
replays every journal after it — verifying the tamper-evidence chain — then
downloads each blob from objects/, decrypts it with age, checks its integrity
hash, and renames it back to its original filename.

    python3 restore.py [output-dir]      # default: ./SnapSiphonRestore
    python3 restore.py --all             # ALSO restore deleted-but-unpurged items
                                         # (disaster mode, e.g. after a library wipe)

Requires: python3, plus ONE of: the `age` CLI (brew install age), or the
Python `cryptography` package (pip3 install cryptography) as a fallback.
macOS: a python.org install ships without root certificates — run its
"Install Certificates.command" once or every download fails with
CERTIFICATE_VERIFY_FAILED. The system python3 or Homebrew's python just work.
⚠️  This file contains live bucket credentials and an age secret key.
    Store it like a password. Anyone holding it can read your entire archive.
"""
import sys
if sys.version_info < (3, 8):
    sys.exit("This script needs Python 3.8 or newer (you have %d.%d)." % sys.version_info[:2])
import base64, datetime, hashlib, hmac, json, os, pathlib, re, shutil, sqlite3
import subprocess, tempfile, time
import urllib.error, urllib.parse, urllib.request, xml.etree.ElementTree as ET

ENDPOINT   = "\#(endpoint)"
REGION     = "\#(region)"
BUCKET     = "\#(bucket)"
PREFIX     = "\#(prefix)"
ACCESS_KEY = "\#(accessKey)"
SECRET_KEY = "\#(secretKey)"      # empty = prompted at run
SESSION_TOKEN = "\#(sessionToken)" # optional AWS STS token
AGE_SECRET = "\#(secret)"         # empty = prompted at run
PATH_STYLE = \#(pathStyle)

S3NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"

# ---------- interactive config review ----------
# Values baked in above are shown for confirmation; anything missing (e.g. a
# secrets-free export) is highlighted and prompted for. ENTER continues,
# a number edits that value. Non-interactive runs skip the review when
# everything needed is present, and fail with a clear list when it isn't.

CONFIG_FIELDS = [
    ("ENDPOINT",   "Endpoint"),
    ("REGION",     "Region"),
    ("BUCKET",     "Bucket"),
    ("PREFIX",     "Prefix"),
    ("PATH_STYLE", "Path style"),
    ("ACCESS_KEY", "Access key"),
    ("SECRET_KEY", "Secret key"),
    ("SESSION_TOKEN", "Session token"),
    ("AGE_SECRET", "Age secret"),
]
OPTIONAL = {"PREFIX", "SESSION_TOKEN"}
HIDDEN = {"SECRET_KEY", "SESSION_TOKEN", "AGE_SECRET"}

def _shown(name, val):
    if name == "PATH_STYLE":
        return str(bool(val))
    if not val:
        return None
    if name == "AGE_SECRET":
        return val[:18] + "…" + val[-4:] if len(val) > 26 else "(set)"
    if name in ("SECRET_KEY", "SESSION_TOKEN"):
        return val[:4] + "…" + val[-4:] if len(val) > 12 else "(set)"
    return str(val)

def configure():
    import getpass
    g = globals()
    color = sys.stdout.isatty()
    def paint(s, code):
        return f"\033[{code}m{s}\033[0m" if color else s
    def missing_names():
        return [label for name, label in CONFIG_FIELDS
                if name not in OPTIONAL and name != "PATH_STYLE" and not g[name]]
    if not sys.stdin.isatty():
        if missing_names():
            sys.exit("Missing required values: " + ", ".join(missing_names())
                     + ". Run interactively to enter them, or edit the script.")
        return
    while True:
        print()
        print(paint("SnapSiphon restore — configuration", "1"))
        for i, (name, label) in enumerate(CONFIG_FIELDS, 1):
            shown = _shown(name, g[name])
            if shown is None:
                shown = paint("(none)", "2") if name in OPTIONAL \
                    else paint("MISSING — required", "1;31")
            elif name in HIDDEN:
                shown = paint(shown, "33")
            print(f"  {i}. {label:<11} {shown}")
        prompt = "ENTER to continue, or a number to change a value: " \
            if not missing_names() else \
            paint("Fill in the missing values (enter a number): ", "1;31")
        try:
            choice = input(prompt).strip()
            if choice == "":
                if not missing_names():
                    return
                continue
            if choice.isdigit() and 1 <= int(choice) <= len(CONFIG_FIELDS):
                name, label = CONFIG_FIELDS[int(choice) - 1]
                if name == "PATH_STYLE":
                    raw = input(f"{label} (true/false) [{g[name]}]: ").strip().lower()
                    if raw:
                        g[name] = raw in ("true", "t", "yes", "y", "1")
                elif name in HIDDEN:
                    raw = getpass.getpass(f"{label} (input hidden): ").strip()
                    if raw:
                        g[name] = raw
                else:
                    raw = input(f"{label} [{g[name] or 'none'}]: ").strip()
                    if raw:
                        g[name] = raw
        except (EOFError, KeyboardInterrupt):
            sys.exit("\nAborted before configuration was confirmed — nothing was restored.")

def s3_open(method, key="", query=None):
    """Signed S3 request (SigV4, UNSIGNED-PAYLOAD) using only the stdlib."""
    query = dict(query or {})
    if PATH_STYLE:
        host = ENDPOINT
        path = "/" + BUCKET + (("/" + urllib.parse.quote(key, safe="/-._~")) if key else "")
    else:
        host = f"{BUCKET}.{ENDPOINT}"
        path = ("/" + urllib.parse.quote(key, safe="/-._~")) if key else "/"
    now = datetime.datetime.now(datetime.timezone.utc)
    amz, ds = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    cq = "&".join(
        f"{urllib.parse.quote(str(k), safe='-._~')}={urllib.parse.quote(str(v), safe='-._~')}"
        for k, v in sorted(query.items()))
    headers = {"host": host, "x-amz-content-sha256": "UNSIGNED-PAYLOAD", "x-amz-date": amz}
    if SESSION_TOKEN:
        headers["x-amz-security-token"] = SESSION_TOKEN
    ch = "".join(f"{k}:{headers[k]}\n" for k in sorted(headers))
    sh = ";".join(sorted(headers))
    creq = "\n".join([method, path, cq, ch, sh, "UNSIGNED-PAYLOAD"])
    scope = f"{ds}/{REGION}/s3/aws4_request"
    sts = "\n".join(["AWS4-HMAC-SHA256", amz, scope, hashlib.sha256(creq.encode()).hexdigest()])
    k = hmac.new(("AWS4" + SECRET_KEY).encode(), ds.encode(), hashlib.sha256).digest()
    for part in (REGION, "s3", "aws4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = (f"AWS4-HMAC-SHA256 Credential={ACCESS_KEY}/{scope}, "
                                f"SignedHeaders={sh}, Signature={sig}")
    url = f"https://{host}{path}" + (f"?{cq}" if cq else "")
    return urllib.request.urlopen(urllib.request.Request(url, method=method, headers=headers),
                                  timeout=60)

RETRYABLE_HTTP = (429, 500, 502, 503, 504)

def _retry(fn, what, attempts=4):
    """Run fn with exponential backoff on transient network/server errors."""
    for i in range(attempts):
        try:
            return fn()
        except urllib.error.HTTPError as e:
            if e.code not in RETRYABLE_HTTP or i == attempts - 1:
                raise
            print(f"  transient HTTP {e.code} on {what} — retry {i + 1}/{attempts - 1}", file=sys.stderr)
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            if i == attempts - 1:
                raise
            print(f"  network hiccup on {what} ({e}) — retry {i + 1}/{attempts - 1}", file=sys.stderr)
        time.sleep(2 ** i)

def list_keys(prefix):
    keys, token = [], None
    while True:
        q = {"list-type": "2", "prefix": prefix}
        if token:
            q["continuation-token"] = token
        root = ET.fromstring(_retry(lambda: s3_open("GET", "", q).read(), "LIST"))
        # Compatible servers vary on whether they emit AWS's XML namespace.
        local = lambda e: e.tag.rsplit("}", 1)[-1]
        for c in root.iter():
            if local(c) == "Contents":
                for e in c:
                    if local(e) == "Key" and e.text:
                        keys.append(e.text)
        tok = next((e for e in root.iter() if local(e) == "NextContinuationToken"), None)
        if tok is None or not tok.text:
            return keys
        token = tok.text

def download(key, dest):
    def go():
        with s3_open("GET", key) as r, open(dest, "wb") as f:
            shutil.copyfileobj(r, f)
    _retry(go, key.rsplit("/", 1)[-1])

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def safe_name(name):
    """Filenames come from the (encrypted) repository, but treat them as
    untrusted anyway: no directories, no traversal, nothing Windows chokes on."""
    name = os.path.basename(str(name).replace("\\", "/")).strip()
    if os.name == "nt":
        name = re.sub(r'[<>:"|?*\x00-\x1f]', "_", name).rstrip(" .")
        stem = name.split(".")[0].upper()
        if stem in {"CON", "PRN", "AUX", "NUL",
                    *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}:
            name = "_" + name
    return "" if name in ("", ".", "..") else name

# ---------- decryption backends ----------
# Preferred: the `age` CLI. Fallback: pure-Python age-v1 decrypt using the
# `cryptography` package (pip3 install cryptography) — Python's stdlib has no
# X25519/ChaCha20, so a third-party lib is unavoidable without the CLI.

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
CHUNK = 64 * 1024

def bech32_decode(s, want_hrp):
    s = s.strip().lower()
    pos = s.rfind("1")
    if pos < 1:
        sys.exit("AGE_SECRET doesn't look like a bech32 key (no separator).")
    hrp, data = s[:pos], s[pos + 1:]
    if hrp != want_hrp:
        sys.exit(f"AGE_SECRET has prefix '{hrp}', expected '{want_hrp}'")
    bad = sorted({c for c in data if c not in CHARSET})
    if bad:
        sys.exit(f"AGE_SECRET contains invalid character(s): {' '.join(bad)} — check for typos or stray whitespace.")
    vals = [CHARSET.index(c) for c in data]
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in ([ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp] + vals):
        top = chk >> 25
        chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5):
            if (top >> i) & 1:
                chk ^= GEN[i]
    if chk != 1:
        sys.exit("AGE_SECRET failed its checksum — mistyped?")
    acc = bits = 0
    out = bytearray()
    for v in vals[:-6]:
        acc = (acc << 5) | v
        bits += 5
        if bits >= 8:
            bits -= 8
            out.append((acc >> bits) & 0xFF)
    return bytes(out)

def hkdf(ikm, salt, info, n=32):
    prk = hmac.new(salt if salt else b"\x00" * 32, ikm, hashlib.sha256).digest()
    t, okm, i = b"", b"", 1
    while len(okm) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        okm += t
        i += 1
    return okm[:n]

def native_decryptor():
    """age-v1 X25519 decrypt via the `cryptography` package, or None."""
    try:
        from cryptography.hazmat.primitives.asymmetric.x25519 import (
            X25519PrivateKey, X25519PublicKey)
        from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
    except ImportError:
        return None
    sk = X25519PrivateKey.from_private_bytes(bech32_decode(AGE_SECRET, "age-secret-key-"))
    pub = sk.public_key().public_bytes_raw()

    def b64d(t):
        return base64.b64decode(t + "=" * (-len(t) % 4))

    def decrypt(src, dest):
        with open(src, "rb") as f:
            head = f.read(65536)
        if not head.startswith(b"age-encryption.org/v1\n"):
            raise ValueError("not an age file")
        mac_at = head.find(b"\n--- ")
        mac_end = head.find(b"\n", mac_at + 1)
        hlen = mac_end + 1
        header_no_mac = head[:mac_at] + b"\n---"
        mac_b64 = head[mac_at + 5:mac_end].decode()

        # find an X25519 stanza our key opens
        lines = head[:mac_at].decode().split("\n")
        file_key = None
        i = 1
        while i < len(lines):
            if lines[i].startswith("-> "):
                args = lines[i][3:].split(" ")
                body, j = "", i + 1
                while j < len(lines) and not lines[j].startswith("-> "):
                    body += lines[j]
                    ln = len(lines[j]); j += 1
                    if ln < 64:
                        break
                i = j
                if args[0] != "X25519" or len(args) != 2:
                    continue
                eph = b64d(args[1])
                shared = sk.exchange(X25519PublicKey.from_public_bytes(eph))
                wrap = hkdf(shared, eph + pub, b"age-encryption.org/v1/X25519")
                try:
                    file_key = ChaCha20Poly1305(wrap).decrypt(b"\x00" * 12, b64d(body), None)
                    break
                except Exception:
                    continue
            else:
                i += 1
        if file_key is None:
            raise ValueError("no stanza matches this key")
        want = hmac.new(hkdf(file_key, b"", b"header"), header_no_mac, hashlib.sha256).digest()
        if base64.b64encode(want).rstrip(b"=").decode() != mac_b64:
            raise ValueError("header MAC mismatch")

        with open(src, "rb") as fin, open(dest, "wb") as fout:
            fin.seek(hlen)
            payload_nonce = fin.read(16)
            aead = ChaCha20Poly1305(hkdf(file_key, payload_nonce, b"payload"))
            counter = 0
            pending = fin.read(CHUNK + 16)
            while True:
                nxt = fin.read(CHUNK + 16)
                last = not nxt
                n12 = counter.to_bytes(11, "big") + (b"\x01" if last else b"\x00")
                fout.write(aead.decrypt(n12, pending, None))
                counter += 1
                if last:
                    break
                pending = nxt

    return decrypt

def make_decryptor(tmp):
    age_bin = shutil.which("age")
    if age_bin:
        ident = pathlib.Path(tmp) / "identity.txt"
        ident.write_text(AGE_SECRET + "\n")
        ident.chmod(0o600)
        print("Decrypting with the age CLI")
        return lambda src, dest: subprocess.run(
            [age_bin, "-d", "-i", str(ident), "-o", str(dest), str(src)], check=True)
    native = native_decryptor()
    if native:
        print("age CLI not found — decrypting in Python via `cryptography`")
        return native
    sys.exit("No decryption backend available. Install one of:\n"
             "  brew install age             (preferred)\n"
             "  pip3 install cryptography    (pure-Python fallback)")

def main():
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    unknown = [f for f in flags if f != "--all"]
    if unknown:
        sys.exit(f"Unknown option(s): {', '.join(unknown)}. Usage: restore.py [output-dir] [--all]")
    restore_all = "--all" in flags
    out = pathlib.Path(args[0] if args else "SnapSiphonRestore")
    out.mkdir(parents=True, exist_ok=True)
    configure()   # review baked-in values; prompt for anything missing

    base = (PREFIX + "/" if PREFIX else "")
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = pathlib.Path(tmpdir)
        decrypt = make_decryptor(tmp)

        # ---- 1. Find the newest complete generation under checkpoints/ ----
        gens = {}
        for k in list_keys(base + "checkpoints/"):
            m = re.match(re.escape(base) + r"checkpoints/(\d+)/(checkpoint|journal(\d+))\.age$", k)
            if not m:
                continue
            seq = 0 if m.group(2) == "checkpoint" else int(m.group(3))
            gens.setdefault(int(m.group(1)), {})[seq] = k
        complete = [g for g, files in gens.items() if 0 in files]
        if not complete:
            sys.exit(f"No checkpoint found under {base}checkpoints/ — nothing to restore.")

        # ---- 2. Load the newest READABLE checkpoint (encrypted SQLite).
        #      A corrupt/undecryptable one falls back to the previous
        #      generation instead of killing the whole restore. ----
        items, gen = None, None
        for candidate in sorted(complete, reverse=True):
            ck_enc, ck_db = tmp / "ckpt.age", tmp / "ckpt.sqlite"
            try:
                ck_enc.unlink(missing_ok=True)
                ck_db.unlink(missing_ok=True)
                download(gens[candidate][0], ck_enc)
                last_hash = sha256_file(ck_enc)
                decrypt(ck_enc, ck_db)
                # Keyed by localIdentifier, NOT blob name: blobs are content-
                # addressed, so identical files share one blob but restore as
                # separate files.
                loaded = {}   # localIdentifier -> {uuid, filename, state, hash}
                con = sqlite3.connect(ck_db)
                for lid, u, state, filename, plain in con.execute(
                        "SELECT localIdentifier, uuid, state, filename, plaintextHash FROM assets WHERE uuid != ''"):
                    if state in ("uploaded", "deleted"):
                        loaded[lid] = {"uuid": u, "filename": filename or "", "state": state, "hash": plain}
                # Blob layout is a repository property recorded in the
                # checkpoint's meta table (absent = old flat layout).
                try:
                    row = con.execute("SELECT value FROM meta WHERE key='repo.layout'").fetchone()
                    sharded = bool(row and row[0] == "sharded2")
                except sqlite3.Error:
                    sharded = False
                con.close()
                items, gen = loaded, candidate
                break
            except Exception as e:
                print(f"WARNING: checkpoint of generation {candidate} is unreadable ({e}) — "
                      "falling back to the previous generation.", file=sys.stderr)
        if items is None:
            sys.exit("No readable checkpoint in any generation — cannot restore.")
        seqs = sorted(s for s in gens[gen] if s > 0)
        print(f"Generation {gen}: checkpoint + {len(seqs)} journal(s)")

        # ---- 3. Replay journals, verifying the tamper-evidence chain. A
        #      single unreadable journal is skipped with a loud warning —
        #      everything else still restores. (Note: the chain proves order
        #      and integrity of what's present; deletion of the newest tail
        #      journal is inherently undetectable within a generation.) ----
        for seq in seqs:
            j_enc, j_json = tmp / f"j{seq}.age", tmp / f"j{seq}.json"
            try:
                download(gens[gen][seq], j_enc)
                raw = j_enc.read_bytes()
                decrypt(j_enc, j_json)
                j = json.loads(j_json.read_text())
            except Exception as e:
                print(f"WARNING: journal {seq} is unreadable ({e}) — skipping it. "
                      "Changes recorded in it will be missing from this restore.", file=sys.stderr)
                if j_enc.exists():
                    last_hash = sha256_file(j_enc)   # keep later chain checks meaningful
                continue
            finally:
                j_enc.unlink(missing_ok=True)
                j_json.unlink(missing_ok=True)
            if j.get("prevHash") != last_hash:
                print(f"WARNING: journal {seq} does not chain to its predecessor — "
                      "the repository history has been altered or partially deleted. "
                      "Restoring what's here anyway.", file=sys.stderr)
            last_hash = hashlib.sha256(raw).hexdigest()
            for e in j.get("entries", []):
                op, u = e.get("op"), e.get("uuid")
                lid = e.get("localIdentifier") or ("blob-" + str(u))
                if op in ("add", "update", "restore"):
                    prev = items.get(lid, {})
                    items[lid] = {"uuid": u,
                                  "filename": e.get("filename") or prev.get("filename", ""),
                                  "state": "uploaded",
                                  "hash": e.get("plaintextHash") or prev.get("hash")}
                elif op == "delete" and lid in items:
                    items[lid]["state"] = "deleted"
                elif op == "purge":
                    items.pop(lid, None)   # blob (or its last reference) gone

        dele = {k: it for k, it in items.items() if it["state"] == "deleted"}
        todo = {k: it for k, it in items.items() if it["state"] == "uploaded"}
        if restore_all:
            todo.update(dele)
            print(f"{len(todo)} items to restore (--all: including {len(dele)} deleted-but-unpurged)")
        else:
            print(f"{len(todo)} items to restore ({len(dele)} deleted, skipped — rerun with --all to include)")

        # Assign every output name up front, deterministically (sorted by
        # filename then identifier, collision suffix derived from the stable
        # identifier) — so a resumed run maps every item to the SAME file it
        # would have gotten the first time.
        plan, used = [], set()
        for lid, it in sorted(todo.items(), key=lambda kv: (kv[1]["filename"], kv[0])):
            name = safe_name(it["filename"]) or it["uuid"]
            if name in used:                                # filename collision
                name = hashlib.sha256(lid.encode()).hexdigest()[:8] + "-" + name
            used.add(name)
            plan.append((lid, it, name))

        done, failed = 0, 0
        restored_by_uuid = {}   # shared blobs: decrypt once, copy for twins
        for i, (lid, it, name) in enumerate(plan, 1):
            u = it["uuid"]
            target = out / name
            if target.is_file() and target.stat().st_size > 0:
                expected = it.get("hash")
                if expected and sha256_file(target) == expected:
                    restored_by_uuid.setdefault(u, target)
                    continue                                # resume: verified restored
                print(f"[{i}/{len(plan)}] existing {name} failed or lacks its recorded SHA-256 — restoring it again",
                      file=sys.stderr)
            blob = tmp / "blob.age"
            part = target.with_name(target.name + ".part")
            part.unlink(missing_ok=True)
            try:
                twin = restored_by_uuid.get(u)
                if twin is not None and twin.exists():
                    shutil.copyfile(twin, part)             # same content, already verified
                else:
                    blob_key = base + ("objects/" + u[:2] + "/" + u if sharded else "objects/" + u)
                    download(blob_key, blob)
                    # Decrypt to a temp name and rename only on success, so an
                    # interrupted/failed decrypt can't leave a partial file that
                    # the resume check above would silently accept as restored.
                    decrypt(blob, part)
                    blob.unlink(missing_ok=True)
                if it.get("hash") and sha256_file(part) != it["hash"]:
                    raise ValueError("decrypted file fails its integrity hash")
                os.replace(part, target)
                restored_by_uuid.setdefault(u, target)
                done += 1
                print(f"[{i}/{len(plan)}] {name}")
            except Exception as e:                          # keep going; report at end
                part.unlink(missing_ok=True)
                failed += 1
                print(f"[{i}/{len(plan)}] FAILED {u}: {e}", file=sys.stderr)
    print(f"Done: {done} restored, {failed} failed → {out}")
    if failed:
        sys.exit(1)

if __name__ == "__main__":
    main()
"""#
    }
}
