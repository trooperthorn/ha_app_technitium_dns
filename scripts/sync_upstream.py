#!/usr/bin/env python3
"""Track the upstream `technitium/dns-server` image this app is built from.

Reads the newest stable tag of technitium/dns-server on Docker Hub and its
manifest-list digest, then rewrites the `FROM technitium/dns-server:...`
pin (and its header comment) in `technitium_dns/Dockerfile` when either has
moved.

Digests are re-checked every run, not only when the tag moves: Technitium
occasionally re-pushes a tag over the same version, and a pin exists
specifically to catch that.

This script does NOT touch the `.NET` runtime-overlay stage above the
Technitium `FROM` line (see the Dockerfile's own comments, "Runtime overlay
to clear High CVEs"). Whether that overlay is still needed is a judgment
call -- Technitium may eventually ship a release built against a patched
runtime on its own, at which point the overlay should be removed rather than
kept -- so a version bump only leaves a note for human review instead of
guessing.

The app version itself (`technitium_dns/config.yaml`) is not touched; the
existing release automation bumps it once this change is merged.

Prints "changed=true" or "changed=false" (also into GITHUB_OUTPUT when set).

Usage:
    python scripts/sync_upstream.py            # apply
    python scripts/sync_upstream.py --check    # report only, no writes
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from datetime import date, UTC, datetime
from pathlib import Path

HUB_API = "https://hub.docker.com/v2"
IMAGE = "technitium/dns-server"
APP_DIR = "technitium_dns"

STABLE_TAG = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
PIN = re.compile(
    r"^FROM " + re.escape(IMAGE) + r":(?P<tag>[0-9]+\.[0-9]+\.[0-9]+)@(?P<digest>sha256:[0-9a-f]{64})$",
    re.MULTILINE,
)
TAG_COMMENT = re.compile(r"^# Pinned tag: " + re.escape(IMAGE) + r":[0-9]+\.[0-9]+\.[0-9]+$", re.MULTILINE)
DIGEST_HEADER = re.compile(
    r"^# Digest \(linux/amd64 manifest list, read from Docker Hub [0-9]{4}-[0-9]{2}-[0-9]{2}\):$",
    re.MULTILINE,
)
DIGEST_LINE = re.compile(r"^#   sha256:[0-9a-f]{64}$", re.MULTILINE)


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "ha_app_technitium_dns sync"})
    # fixed https host only
    with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310
        return response.read().decode("utf-8")


def latest_stable_tag() -> dict:
    """
    Find the newest stable (X.Y.Z) tag on Docker Hub and its digest.

    :return: The tag entry as returned by Docker Hub, including "name" and
        the manifest-list "digest".
    """
    url = f"{HUB_API}/repositories/{IMAGE}/tags?page_size=100&ordering=last_updated"
    best: tuple[int, int, int] | None = None
    best_entry: dict | None = None
    while url:
        page = json.loads(fetch(url))
        for entry in page.get("results", []):
            name = entry.get("name", "")
            if not STABLE_TAG.match(name):
                continue
            parts = tuple(int(p) for p in name.split("."))
            if best is None or parts > best:
                best = parts
                best_entry = entry
        url = page.get("next")
    if best_entry is None:
        raise RuntimeError(f"no stable X.Y.Z tag found for {IMAGE} on Docker Hub")
    digest = best_entry.get("digest", "")
    if not DIGEST.match(digest):
        raise RuntimeError(f"{IMAGE}:{best_entry.get('name')} returned no usable digest ({digest!r})")
    return best_entry


def read_pin(dockerfile: str) -> tuple[str, str]:
    match = PIN.search(dockerfile)
    if match is None:
        raise RuntimeError(f"Dockerfile has no recognizable FROM {IMAGE}:X.Y.Z@sha256:... pin")
    return match["tag"], match["digest"]


def set_pin(dockerfile: str, tag: str, digest: str, today: date) -> str:
    dockerfile, count = PIN.subn(f"FROM {IMAGE}:{tag}@{digest}", dockerfile)
    if count != 1:
        raise RuntimeError(f"Dockerfile has {count} FROM {IMAGE} pins, expected one")
    dockerfile, count = TAG_COMMENT.subn(f"# Pinned tag: {IMAGE}:{tag}", dockerfile)
    if count != 1:
        raise RuntimeError(f"Dockerfile has {count} 'Pinned tag' comments, expected one")
    dockerfile, count = DIGEST_HEADER.subn(
        f"# Digest (linux/amd64 manifest list, read from Docker Hub {today:%Y-%m-%d}):", dockerfile
    )
    if count != 1:
        raise RuntimeError(f"Dockerfile has {count} digest-header comments, expected one")
    dockerfile, count = DIGEST_LINE.subn(f"#   {digest}", dockerfile)
    if count != 1:
        raise RuntimeError(f"Dockerfile has {count} digest comment lines, expected one")
    return dockerfile


def changelog_entry(lines: list[str]) -> str:
    return "".join(f"- {line}\n" for line in lines)


def prepend_unreleased(text: str, lines: list[str]) -> str:
    """Add the lines under the '## Unreleased' heading, creating it if absent."""
    heading = "## Unreleased\n"
    idx = text.find(heading)
    if idx == -1:
        head, sep, rest = text.partition("\n\n")
        return head + sep + heading + "\n" + changelog_entry(lines) + "\n" + rest
    insert_at = idx + len(heading) + 1
    return text[:insert_at] + changelog_entry(lines) + text[insert_at:]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="report without writing")
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    app = args.repository / APP_DIR
    dockerfile_path = app / "Dockerfile"
    dockerfile = dockerfile_path.read_text(encoding="utf-8")

    current_tag, current_digest = read_pin(dockerfile)
    upstream = latest_stable_tag()
    new_tag, new_digest = upstream["name"], upstream["digest"]

    changes: list[str] = []
    if new_tag != current_tag:
        changes.append(f"Technitium DNS Server {current_tag} -> {new_tag}")
    elif new_digest != current_digest:
        changes.append(f"{IMAGE}:{new_tag} re-published: digest {current_digest} -> {new_digest}")
    if new_tag != current_tag:
        changes.append(
            "Review the runtime-overlay rationale comments in the Dockerfile (\"Runtime overlay to clear "
            f"High CVEs\"): confirm whether {IMAGE}:{new_tag} still bundles a vulnerable .NET runtime, and "
            "whether the overlay's own pinned aspnet patch version is still the newest available."
        )

    changed = new_tag != current_tag or new_digest != current_digest
    if changed and not args.check:
        today = datetime.now(UTC).date()
        dockerfile_path.write_text(set_pin(dockerfile, new_tag, new_digest, today), encoding="utf-8", newline="\n")
        changelog = app / "CHANGELOG.md"
        changelog.write_text(prepend_unreleased(changelog.read_text(encoding="utf-8"), changes), encoding="utf-8", newline="\n")

    for line in changes:
        print(f"change: {line}")
    flag = "true" if changed else "false"
    print(f"changed={flag}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as fh:
            fh.write(f"changed={flag}\n")
            fh.write("summary<<SUMMARY_END\n" + "\n".join(changes) + "\nSUMMARY_END\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
