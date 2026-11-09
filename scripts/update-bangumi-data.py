#!/usr/bin/env python3
"""Refresh the bundled index from an explicitly pinned npm release."""
import argparse
import base64
import hashlib
import io
import json
import re
import tarfile
from pathlib import Path
from urllib.request import urlopen

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("version", nargs="?", default="0.3.235")
args = parser.parse_args()
if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
    parser.error("provide a fixed numeric release version")

registry = "https://registry.npmjs.org/bangumi-data"
tarball = f"{registry}/-/bangumi-data-{args.version}.tgz"
with urlopen(f"{registry}/{args.version}", timeout=30) as response:
    release = json.load(response)
with urlopen(tarball, timeout=60) as response:
    archive = response.read()
integrity = "sha512-" + base64.b64encode(hashlib.sha512(archive).digest()).decode()
if release["dist"]["integrity"] != integrity or release["license"] != "CC-BY-4.0":
    raise SystemExit("Package integrity or license changed")
if args.version == "0.3.235" and integrity != (
    "sha512-34e5OWp2naCGyeGfEcPRl+FBz5wbESGN36qa8KMXQy0gz7caPUQAn2xH5LWGCqAsIUtLFb3bzb+8hO98NauCPQ=="
):
    raise SystemExit("Pinned release differs from the audited release")
with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as package:
    upstream = package.extractfile("package/dist/data.json").read()
source = json.loads(upstream)
info_sites = {k for k, v in source["siteMeta"].items() if v["type"] == "info"}
items = []
for item in source["items"]:
    kind = item["type"]
    if kind not in ("tv", "web", "movie", "ova"):
        raise SystemExit(f"Unsupported upstream type: {kind}")
    ids = {}
    for link in item["sites"]:
        if link["site"] in info_sites and link["id"]:
            ids.setdefault(link["site"], set()).add(link["id"])
    # A repeated site with conflicting IDs is not a reliable identity.
    ids = {site: next(iter(values)) for site, values in ids.items() if len(values) == 1}
    items.append([item["title"], item.get("titleTranslate", {}), kind, item.get("begin", ""), ids])

def encode(value):
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode()

output = Path(__file__).resolve().parents[1] / "assets/metadata"
output.mkdir(parents=True, exist_ok=True)
asset = encode({"schema": 1, "items": items})
(output / "bangumi-data.json").write_bytes(asset)
manifest = {
    "version": args.version,
    "commit": release["gitHead"],
    "source": "https://github.com/bangumi-data/bangumi-data",
    "license": "https://creativecommons.org/licenses/by/4.0/",
    "tarball": tarball,
    "tarballIntegrity": integrity,
    "upstreamSha256": hashlib.sha256(upstream).hexdigest(),
    "assetSha256": hashlib.sha256(asset).hexdigest(),
    "entries": len(items),
    "bytes": len(asset),
}
(output / "bangumi-data-manifest.json").write_bytes(
    (json.dumps(manifest, indent=2) + "\n").encode()
)
print(json.dumps(manifest, indent=2))
