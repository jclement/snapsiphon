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

Requires: python3 (stdlib only) and the `age` CLI (https://age-encryption.org).
⚠️  This file contains live bucket credentials and an age secret key.
    Store it like a password. Anyone holding it can read your entire archive.
"""
import datetime, hashlib, hmac, json, os, pathlib, shutil, subprocess, sys, tempfile
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

def age_decrypt(src, dest, identity):
    subprocess.run(["age", "-d", "-i", identity, "-o", str(dest), str(src)], check=True)

def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "SnapSiphonRestore")
    out.mkdir(parents=True, exist_ok=True)
    if not shutil.which("age"):
        sys.exit("The `age` CLI is required (brew install age / apt install age).")
    if AGE_SECRET.startswith("PASTE-"):
        sys.exit("Edit this script and fill in AGE_SECRET with your age secret key.")

    with tempfile.TemporaryDirectory() as tmp:
        ident = pathlib.Path(tmp) / "identity.txt"
        ident.write_text(AGE_SECRET + "\n")
        ident.chmod(0o600)

        mprefix = (PREFIX + "/" if PREFIX else "") + "manifests/"
        manifests = sorted(list_keys(mprefix))
        if not manifests:
            sys.exit(f"No manifests found under {mprefix} — nothing to restore.")
        latest = manifests[-1]
        print(f"Using manifest {latest}")
        mblob = pathlib.Path(tmp) / "manifest.age"
        mjson = pathlib.Path(tmp) / "manifest.json"
        download(latest, mblob)
        age_decrypt(mblob, mjson, ident)
        manifest = json.loads(mjson.read_text())

        deleted = set(manifest.get("deletedKeys", []))
        items = [i for i in manifest["items"] if i["key"] not in deleted]
        print(f"{len(items)} items to restore ({len(deleted)} tombstoned, skipped)")

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
                age_decrypt(blob, target, ident)
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
