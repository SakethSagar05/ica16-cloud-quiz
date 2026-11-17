"""Prints a Firestore REST listing with IDs shortened to six-character suffixes.

Reads the REST JSON response on stdin. Mode "owner" lists documents; mode
"other" reports whether the read was denied. No credentials are handled here.
"""
import json
import os
import sys

mode = sys.argv[1]
uid_suffix = os.environ.get("SUFFIX_UID", "")
data = json.load(sys.stdin)
err = data.get("error")
if mode == "other":
    if err:
        print("DENIED:", err.get("code"), err.get("status"), err.get("message", ""))
    else:
        print("UNEXPECTEDLY ALLOWED: documents returned =", len(data.get("documents", [])))
    sys.exit(0)
if err:
    print("error:", err.get("code"), err.get("status"), err.get("message", ""))
    sys.exit(1)
docs = data.get("documents", [])
print("documents:", len(docs))
for doc in sorted(docs, key=lambda d: d.get("createTime", "")):
    rid = doc["name"].rsplit("/", 1)[-1]
    fields = {k: list(v.values())[0] for k, v in doc.get("fields", {}).items()}
    same = "yes" if doc.get("createTime") == doc.get("updateTime") else "NO"
    print("- users/..%s/attempts/..%s" % (uid_suffix, rid[-6:]))
    print("    createTime=%s updateTime=%s never_updated=%s" % (doc.get("createTime"), doc.get("updateTime"), same))
    print("    " + ", ".join("%s=%s" % (k, fields[k]) for k in sorted(fields)))
