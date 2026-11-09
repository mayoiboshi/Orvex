#!/usr/bin/env python3
"""Build the offline alias asset from a pinned anime-offline-database release."""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from urllib.request import urlopen

RELEASE = "2026-44"
PROJECT = "https://github.com/cedya77/anime-offline-database"
URL = f"{PROJECT}/releases/download/{RELEASE}/anime-offline-database-minified.json.zst"
SHA256 = "0094a4617a14671f564160294bbd121d82e9cd76805903d02c7df080d37639ab"
KINDS = {"tv": "TV", "web": "ONA", "movie": "MOVIE", "ova": "OVA"}
SOURCES = {
    "aniList": r"https://anilist\.co/anime/([0-9]+)",
    "mal": r"https://myanimelist\.net/anime/([0-9]+)",
    "anidb": r"https://anidb\.net/anime/([0-9]+)",
}


def normalized(text):
    return "".join(c for c in unicodedata.normalize("NFKC", text).casefold() if c.isalnum())


def latin_title(text):
    letters = [c for c in text if c.isalpha()]
    return len(letters) >= 3 and all("LATIN" in unicodedata.name(c, "") for c in letters)


def build_aliases(base, rows):
    source_rows = defaultdict(set)
    row_ids = []
    for index, row in enumerate(rows):
        ids = defaultdict(set)
        for url in row["sources"]:
            for site, pattern in SOURCES.items():
                if match := re.fullmatch(pattern, url):
                    ids[site].add(match[1])
                    source_rows[(site, match[1])].add(index)
        row_ids.append(ids)

    bgm_counts = Counter(entry[-1].get("bangumi") for entry in base)
    aliases = {}
    for title, translations, kind, begin, ids in base:
        bgm = ids.get("bangumi")
        if not bgm or bgm_counts[bgm] != 1:
            continue
        existing = {site: ids[site] for site in SOURCES if site in ids}
        rows_found = set().union(*(source_rows[(site, value)] for site, value in existing.items()))
        # One row must agree with at least two providers. A conflicting or
        # ambiguous cross-link, edition, or premiere year is left unchanged.
        if len(rows_found) != 1:
            continue
        index = next(iter(rows_found))
        external = row_ids[index]
        if any(site in external and external[site] != {value} for site, value in existing.items()):
            continue
        if sum(site in external for site in existing) < 2:
            continue
        row = rows[index]
        if row["type"] != KINDS.get(kind):
            continue
        if not begin[:4].isdigit() or row.get("animeSeason", {}).get("year") != int(begin[:4]):
            continue
        canonical = row["title"].strip()
        names = [title, *(alias for values in translations.values() for alias in values)]
        if latin_title(canonical) and normalized(canonical) not in {normalized(name) for name in names}:
            aliases[bgm] = canonical
    return aliases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="use the already downloaded pinned archive")
    args = parser.parse_args()
    directory = Path(__file__).resolve().parents[1] / "assets" / "metadata"
    base = json.loads((directory / "bangumi-data.json").read_bytes())
    with tempfile.TemporaryDirectory() as temporary:
        archive = args.archive or Path(temporary) / "catalog.json.zst"
        if not args.archive:
            with urlopen(URL, timeout=60) as response:
                archive.write_bytes(response.read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
            raise SystemExit("Archive checksum differs from pinned release")
        source = json.loads(subprocess.check_output(["zstd", "-dc", str(archive)]))
    aliases = build_aliases(base["items"], source["data"])
    asset = {
        "schema": 1,
        "source": URL,
        "sourceSha256": SHA256,
        "databaseLicense": "https://opendatacommons.org/licenses/odbl/1-0/",
        "contentsLicense": "https://opendatacommons.org/licenses/dbcl/1-0/",
        "aliases": dict(sorted(aliases.items(), key=lambda item: int(item[0]))),
    }
    path = directory / "romanized-aliases.json"
    path.write_text(json.dumps(asset, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{len(aliases)} titles, {path.stat().st_size} bytes, SHA-256 {hashlib.sha256(path.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
