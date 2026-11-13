#!/usr/bin/env python3
"""Contrôle turktv.m3u et renouvelle seulement les sources officielles configurées."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

USER_AGENT = "Mozilla/5.0 (TURKTV official stream monitor)"
TIMEOUT = 15
FORBIDDEN = re.compile(
    r"kurd|kurdî|kurdistan|kurdi|kurman|soran|zagros|rûdaw|rudaw|welat|"
    r"jîn|jin tv|zarok|trt world|trt arabi",
    re.IGNORECASE,
)
HLS_URL = re.compile(r"https?://[^\s\"'<>\\]+?\.m3u8(?:\?[^\s\"'<>\\]*)?", re.IGNORECASE)


@dataclass
class Entry:
    name: str
    info_index: int
    url_index: int
    url: str


def request(url: str, *, limit: int = 512_000) -> tuple[int, str, str, str]:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    last_error: Exception | None = None
    for attempt in range(2):
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
                body = response.read(limit).decode("utf-8", errors="replace")
                return response.status, response.headers.get("Content-Type", ""), body, response.geturl()
        except urllib.error.HTTPError as exc:
            if exc.code not in (408, 429, 500, 502, 503, 504) or attempt == 1:
                raise
            last_error = exc
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            if attempt == 1:
                raise
            last_error = exc
        time.sleep(1)
    raise last_error or RuntimeError("requête impossible")


def parse_playlist(lines: list[str]) -> list[Entry]:
    entries: list[Entry] = []
    for index, line in enumerate(lines):
        if not line.startswith("#EXTINF"):
            continue
        name = line.rsplit(",", 1)[1].strip() if "," in line else "Chaîne sans nom"
        url_index = index + 1
        while url_index < len(lines) and (not lines[url_index].strip() or lines[url_index].startswith("#")):
            url_index += 1
        if url_index < len(lines):
            entries.append(Entry(name, index, url_index, lines[url_index].strip()))
    return entries


def validate_hls(url: str) -> tuple[bool, str]:
    try:
        status, _, manifest, final_url = request(url)
        if status != 200 or "#EXTM3U" not in manifest:
            return False, f"manifeste HTTP {status} ou format incorrect"
        candidates = [line.strip() for line in manifest.splitlines() if line.strip() and not line.startswith("#")]
        if not candidates:
            return False, "manifeste sans média"
        errors: list[str] = []
        # Certains diffuseurs laissent une ancienne qualité en première position.
        # On essaie plusieurs variantes avant de déclarer toute la chaîne en panne.
        for candidate in candidates[:8]:
            target = urllib.parse.urljoin(final_url, candidate)
            try:
                if target.lower().split("?", 1)[0].endswith(".m3u8"):
                    child_status, _, child, child_url = request(target)
                    if child_status != 200 or "#EXTM3U" not in child:
                        errors.append(f"variante HTTP {child_status}")
                        continue
                    media = [line.strip() for line in child.splitlines() if line.strip() and not line.startswith("#")]
                    if not media:
                        errors.append("variante sans segment")
                        continue
                    target = urllib.parse.urljoin(child_url, media[0])
                req = urllib.request.Request(
                    target,
                    headers={"User-Agent": USER_AGENT, "Range": "bytes=0-4095"},
                )
                for attempt in range(2):
                    try:
                        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
                            response.read(4096)
                            if response.status in (200, 206):
                                return True, "manifeste et segment accessibles"
                            errors.append(f"segment HTTP {response.status}")
                    except (urllib.error.URLError, TimeoutError, ConnectionError):
                        if attempt == 1:
                            raise
                        time.sleep(1)
            except Exception as exc:
                errors.append(type(exc).__name__)
        return False, "aucune variante vidéo accessible: " + ", ".join(errors[:4])
    except Exception as exc:  # Le détail reste sans URL ni secret.
        return False, f"{type(exc).__name__}: {str(exc)[:120]}"


def renew_from_official_page(rule: dict) -> tuple[str | None, str]:
    try:
        _, _, html, _ = request(rule["page"], limit=2_000_000)
        allowed = {host.lower() for host in rule["allowed_stream_hosts"]}
        candidates: list[str] = []
        for raw in HLS_URL.findall(html.replace("\\/", "/").replace("&amp;", "&")):
            candidate = raw.rstrip(".,);]")
            if urllib.parse.urlparse(candidate).hostname in allowed and candidate not in candidates:
                candidates.append(candidate)
        for candidate in candidates:
            valid, reason = validate_hls(candidate)
            if valid:
                return candidate, reason
        return None, "aucun flux officiel valide trouvé"
    except Exception as exc:
        return None, f"page officielle inaccessible: {type(exc).__name__}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--playlist", default="turktv.m3u")
    parser.add_argument("--config", default="automation/sources.json")
    parser.add_argument("--mode", choices=("priority", "full"), default="priority")
    args = parser.parse_args()

    playlist_path = Path(args.playlist)
    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    original = playlist_path.read_text(encoding="utf-8-sig")
    if "@{value=" in original:
        print("ERREUR: métadonnées M3U corrompues détectées", file=sys.stderr)
        return 2
    if "x-tvg-url=" not in original.splitlines()[0].casefold():
        print("ERREUR: adresse EPG absente de l'en-tête M3U", file=sys.stderr)
        return 2
    newline = "\r\n" if "\r\n" in original else "\n"
    lines = original.splitlines()
    entries = parse_playlist(lines)
    by_name = {entry.name.casefold(): entry for entry in entries}

    forbidden = [entry.name for entry in entries if FORBIDDEN.search(entry.name + " " + entry.url)]
    if forbidden:
        print("ERREUR: chaîne interdite détectée: " + ", ".join(forbidden), file=sys.stderr)
        return 2

    changes: list[str] = []
    renewal_errors: list[str] = []
    for rule in config.get("renewers", []):
        entry = by_name.get(rule["channel"].casefold())
        if not entry:
            renewal_errors.append(f"{rule['channel']}: absente de la playlist")
            continue
        if rule.get("type") != "official_webpage":
            renewal_errors.append(f"{entry.name}: méthode de renouvellement non prise en charge")
            continue
        fresh_url, reason = renew_from_official_page(rule)
        if fresh_url:
            if fresh_url != entry.url:
                lines[entry.url_index] = fresh_url
                entry.url = fresh_url
                changes.append(entry.name)
            print(f"RENOUVELLEMENT {entry.name}: source officielle valide ({reason})")
        else:
            renewal_errors.append(f"{entry.name}: {reason}")

    if changes:
        playlist_path.write_text(newline.join(lines) + newline, encoding="utf-8", newline="")

    selected = entries
    if args.mode == "priority":
        wanted = {name.casefold() for name in config.get("priority_channels", [])}
        selected = [entry for entry in entries if entry.name.casefold() in wanted]

    results: list[tuple[str, bool, str]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = {executor.submit(validate_hls, entry.url): entry.name for entry in selected}
        for future in concurrent.futures.as_completed(futures):
            ok, reason = future.result()
            results.append((futures[future], ok, reason))

    results.sort(key=lambda item: item[0].casefold())
    failures = [item for item in results if not item[1]]
    print(f"RÉSUMÉ: {len(results) - len(failures)}/{len(results)} chaînes accessibles; mode={args.mode}")
    for name, _, reason in failures:
        print(f"ÉCHEC {name}: {reason}")
    for message in renewal_errors:
        print("ALERTE RENOUVELLEMENT " + message)
    if changes:
        print("MISE À JOUR: " + ", ".join(changes))

    # Les pannes statiques sont signalées mais ne provoquent aucun remplacement hasardeux.
    # Un échec de renouvellement officiel fait échouer l'action pour rendre l'alerte visible.
    return 1 if renewal_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
