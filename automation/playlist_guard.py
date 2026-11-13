#!/usr/bin/env python3
"""Bloque une publication TURKTV qui dégraderait la playlist de référence."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from refresh_streams import FORBIDDEN, parse_playlist


def inspect(playlist: Path) -> tuple[str, list]:
    text = playlist.read_text(encoding="utf-8-sig")
    return text, parse_playlist(text.splitlines())


def write_baseline(playlist: Path, baseline_path: Path) -> None:
    text, entries = inspect(playlist)
    header = text.splitlines()[0] if text.splitlines() else ""
    match = re.search(r'x-tvg-url="([^"]+)"', header, flags=re.IGNORECASE)
    baseline = {
        "version": 1,
        "minimum_channel_count": len(entries),
        "minimum_tvg_ids": len(re.findall(r'tvg-id="[^"]+"', text, flags=re.IGNORECASE)),
        "required_epg_url": match.group(1) if match else "",
        "priority_order": [entry.name for entry in entries[:14]],
        "required_channels": [entry.name for entry in entries],
    }
    baseline_path.write_text(
        json.dumps(baseline, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Référence créée: {len(entries)} chaînes")


def validate(playlist: Path, baseline_path: Path) -> int:
    text, entries = inspect(playlist)
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    errors: list[str] = []
    names = [entry.name for entry in entries]
    folded = {name.casefold() for name in names}

    if len(entries) < baseline["minimum_channel_count"]:
        errors.append(
            f"nombre de chaînes réduit: {len(entries)} au lieu de {baseline['minimum_channel_count']} minimum"
        )
    if len(folded) != len(names):
        errors.append("noms de chaînes en double")

    missing = [name for name in baseline["required_channels"] if name.casefold() not in folded]
    if missing:
        errors.append("chaînes supprimées: " + ", ".join(missing))

    actual_priority = names[: len(baseline["priority_order"])]
    if actual_priority != baseline["priority_order"]:
        errors.append("ordre des 14 chaînes prioritaires modifié")

    header = text.splitlines()[0] if text.splitlines() else ""
    if baseline["required_epg_url"] not in header:
        errors.append("adresse EPG supprimée ou remplacée sans validation")

    tvg_ids = len(re.findall(r'tvg-id="[^"]+"', text, flags=re.IGNORECASE))
    if tvg_ids < baseline["minimum_tvg_ids"]:
        errors.append(
            f"identifiants EPG réduits: {tvg_ids} au lieu de {baseline['minimum_tvg_ids']} minimum"
        )
    if "@{value=" in text:
        errors.append("lignes EXTINF corrompues")

    forbidden = [entry.name for entry in entries if FORBIDDEN.search(entry.name + " " + entry.url)]
    if forbidden:
        errors.append("chaînes interdites détectées: " + ", ".join(forbidden))

    invalid = [entry.name for entry in entries if not re.match(r"^https?://", entry.url, flags=re.IGNORECASE)]
    if invalid:
        errors.append("adresses invalides: " + ", ".join(invalid))

    if errors:
        print("PUBLICATION BLOQUÉE — régression détectée", file=sys.stderr)
        for error in errors:
            print("- " + error, file=sys.stderr)
        return 1
    print(
        f"GARDE ANTI-RÉGRESSION: OK — {len(entries)} chaînes, {tvg_ids} identifiants EPG"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--playlist", default="turktv.m3u")
    parser.add_argument("--baseline", default="automation/playlist_baseline.json")
    parser.add_argument("--write-baseline", action="store_true")
    args = parser.parse_args()
    playlist = Path(args.playlist)
    baseline = Path(args.baseline)
    if args.write_baseline:
        write_baseline(playlist, baseline)
        return 0
    return validate(playlist, baseline)


if __name__ == "__main__":
    raise SystemExit(main())
