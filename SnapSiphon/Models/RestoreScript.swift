import Foundation

/// Builds the "break-glass" disaster-recovery script: a single self-contained
/// Python file with the bucket credentials and (if held) the age secret baked
/// in. Save that one file somewhere safe and a laptop can rebuild the whole
/// photo archive with `python3 restore.py` — no SnapSiphon, no SDKs.
///
/// ⚠️ The output contains live secrets in plaintext. The UI copies it behind a
/// warning and tells the user to store it like a password (it *is* one).
///
/// Runtime needs: python3 (stdlib only — SigV4 is implemented inline) and the
/// `age` CLI (`brew install age`) for decryption.
enum RestoreScript {
    static func build(config: S3Config, credentials: S3Credentials, ageSecret: String?) -> String {
        let secret = ageSecret ?? "PASTE-YOUR-AGE-SECRET-KEY-HERE"
        let prefix = config.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let pathStyle = config.provider.usesPathStyle ? "True" : "False"
        return #"""
#!/usr/bin/env python3
"""SnapSiphon disaster-recovery restore.

Downloads every backed-up photo/video from the bucket, decrypts it with age,
and renames it back to its original filename using the encrypted manifest.

    python3 restore.py [output-dir]      # default: ./SnapSiphonRestore
    python3 restore.py --all             # ALSO restore deleted-but-unpurged items
                                         # (disaster mode, e.g. after a library wipe)

Requires: python3, plus ONE of: the `age` CLI (brew install age), or the
Python `cryptography` package (pip3 install cryptography) as a fallback.
⚠️  This file contains live bucket credentials and an age secret key.
    Store it like a password. Anyone holding it can read your entire archive.
"""
import base64, datetime, hashlib, hmac, json, os, pathlib, shutil, subprocess, sys, tempfile
import urllib.parse, urllib.request, xml.etree.ElementTree as ET

ENDPOINT   = "\#(config.endpoint)"
REGION     = "\#(config.region)"
BUCKET     = "\#(config.bucket)"
PREFIX     = "\#(prefix)"
ACCESS_KEY = "\#(credentials.accessKeyID)"
SECRET_KEY = "\#(credentials.secretAccessKey)"
AGE_SECRET = "\#(secret)"
PATH_STYLE = \#(pathStyle)

S3NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"

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
    return urllib.request.urlopen(urllib.request.Request(url, method=method, headers=headers))

def list_keys(prefix):
    keys, token = [], None
    while True:
        q = {"list-type": "2", "prefix": prefix}
        if token:
            q["continuation-token"] = token
        root = ET.fromstring(s3_open("GET", "", q).read())
        keys += [e.text for c in root.iter(S3NS + "Contents") for e in c.iter(S3NS + "Key")]
        tok = root.find(S3NS + "NextContinuationToken")
        if tok is None or not tok.text:
            return keys
        token = tok.text

def download(key, dest):
    with s3_open("GET", key) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f)

# ---------- decryption backends ----------
# Preferred: the `age` CLI. Fallback: pure-Python age-v1 decrypt using the
# `cryptography` package (pip3 install cryptography) — Python's stdlib has no
# X25519/ChaCha20, so a third-party lib is unavoidable without the CLI.

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
CHUNK = 64 * 1024

def bech32_decode(s, want_hrp):
    s = s.lower()
    pos = s.rfind("1")
    hrp, data = s[:pos], s[pos + 1:]
    if hrp != want_hrp:
        sys.exit(f"AGE_SECRET has prefix '{hrp}', expected '{want_hrp}'")
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
    restore_all = "--all" in flags
    out = pathlib.Path(args[0] if args else "SnapSiphonRestore")
    out.mkdir(parents=True, exist_ok=True)
    if AGE_SECRET.startswith("PASTE-"):
        sys.exit("Edit this script and fill in AGE_SECRET with your age secret key.")

    with tempfile.TemporaryDirectory() as tmp:
        decrypt = make_decryptor(tmp)

        mprefix = (PREFIX + "/" if PREFIX else "") + "manifests/"
        manifests = sorted(list_keys(mprefix))
        if not manifests:
            sys.exit(f"No manifests found under {mprefix} — nothing to restore.")
        latest = manifests[-1]
        print(f"Using manifest {latest}")
        mblob = pathlib.Path(tmp) / "manifest.age"
        mjson = pathlib.Path(tmp) / "manifest.json"
        download(latest, mblob)
        decrypt(mblob, mjson)
        manifest = json.loads(mjson.read_text())

        deleted = set(manifest.get("deletedKeys", []))
        if restore_all:
            items = manifest["items"] + manifest.get("deleted", [])
            print(f"{len(items)} items to restore (--all: including {len(deleted)} deleted-but-unpurged)")
        else:
            items = [i for i in manifest["items"] if i["key"] not in deleted]
            print(f"{len(items)} items to restore ({len(deleted)} deleted, skipped — rerun with --all to include)")

        used, done, failed = {}, 0, 0
        for i, item in enumerate(items, 1):
            name = item["filename"] or (item["key"].split("/")[-1].removesuffix(".age"))
            if used.get(name) not in (None, item["key"]):   # filename collision
                name = hashlib.sha256(item["key"].encode()).hexdigest()[:8] + "-" + name
            used[name] = item["key"]
            target = out / name
            if target.exists() and target.stat().st_size > 0:
                continue                                    # resume: already restored
            blob = pathlib.Path(tmp) / "blob.age"
            try:
                download(item["key"], blob)
                decrypt(blob, target)
                done += 1
                print(f"[{i}/{len(items)}] {name}")
            except Exception as e:                          # keep going; report at end
                failed += 1
                print(f"[{i}/{len(items)}] FAILED {item['key']}: {e}", file=sys.stderr)
    print(f"Done: {done} restored, {failed} failed → {out}")

if __name__ == "__main__":
    main()
"""#
    }
}
