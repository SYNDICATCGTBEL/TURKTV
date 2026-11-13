#!/usr/bin/env python3
"""Répare les métadonnées M3U et associe les chaînes au guide XMLTV retenu."""

from __future__ import annotations

import re
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

PLAYLIST = Path("turktv.m3u")
EPG_URL = "https://www.open-epg.com/files/turkey3.xml"


def normalize(value: str) -> str:
    value = re.sub(r"^\s*TR\s*-\s*", "", value, flags=re.IGNORECASE)
    value = re.sub(r"\.tr$", "", value, flags=re.IGNORECASE)
    value = re.sub(r"\([^)]*(?:p|Turkiye)[^)]*\)", "", value, flags=re.IGNORECASE)
    value = re.sub(r"\[[^]]+\]|\b(?:HD|SD|FHD)\b", "", value, flags=re.IGNORECASE)
    return "".join(char for char in value.casefold() if char.isalnum())


def main() -> None:
    original = PLAYLIST.read_text(encoding="utf-8-sig")
    newline = "\r\n" if "\r\n" in original else "\n"
    lines = original.splitlines()

    request = urllib.request.Request(EPG_URL, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        root = ET.fromstring(response.read())

    epg_by_name: dict[str, set[str]] = {}
    for channel in root.findall("channel"):
        channel_id = channel.attrib.get("id", "").strip()
        for display_name in channel.findall("display-name"):
            key = normalize(display_name.text or "")
            if key and channel_id:
                epg_by_name.setdefault(key, set()).add(channel_id)

    if lines and lines[0].startswith("#EXTM3U"):
        lines[0] = f'#EXTM3U x-tvg-url="{EPG_URL}"'

    repaired = 0
    matched = 0
    for index, line in enumerate(lines):
        if not line.startswith("#EXTINF"):
            continue

        corrupt = re.match(r'^(#EXTINF:-1\s+tvg-chno="\d+"\s+)@\{value=#EXTINF:-1\s*(.*)$', line)
        if corrupt:
            line = corrupt.group(1) + corrupt.group(2)
            repaired += 1

        name = line.rsplit(",", 1)[1].strip() if "," in line else ""
        tvg_name_match = re.search(r'tvg-name="([^"]+)"', line, flags=re.IGNORECASE)
        keys = {normalize(name)}
        if tvg_name_match:
            keys.add(normalize(tvg_name_match.group(1)))

        ids: set[str] = set()
        for key in keys:
            ids.update(epg_by_name.get(key, set()))
        if len(ids) == 1:
            channel_id = next(iter(ids))
            if re.search(r'tvg-id="[^"]*"', line, flags=re.IGNORECASE):
                line = re.sub(
                    r'tvg-id="[^"]*"',
                    f'tvg-id="{channel_id}"',
                    line,
                    count=1,
                    flags=re.IGNORECASE,
                )
            else:
                line = line.replace("#EXTINF:-1", f'#EXTINF:-1 tvg-id="{channel_id}"', 1)
            matched += 1
        lines[index] = line

    PLAYLIST.write_text(newline.join(lines) + newline, encoding="utf-8", newline="")
    print(f"Lignes corrompues réparées: {repaired}")
    print(f"Chaînes associées à l'EPG: {matched}")


if __name__ == "__main__":
    main()
