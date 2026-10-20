#!/usr/bin/env python3
"""Проверка открытых подписок и сборка catalog/catalog.json.

Запускается в GitHub Actions по расписанию (см. .github/workflows/catalog.yml).
Только стандартная библиотека Python.

  python3 tools/catalog.py                # проверить и записать catalog/catalog.json
  python3 tools/catalog.py --tcp          # плюс выборочный TCP-пинг узлов
  python3 tools/catalog.py --dry-run      # только отчёт
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures as cf
import datetime as dt
import hashlib
import json
import os
import random
import re
import socket
import sys
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "catalog", "sources.json")
OUTPUT = os.path.join(ROOT, "catalog", "catalog.json")
ASSET = os.path.join(ROOT, "assets", "catalog.json")

MAX_BODY = 8 * 1024 * 1024
TIMEOUT = 25
UA = "Locman-catalog/1"
SCHEMES = ("vless", "vmess", "trojan", "ss", "hysteria2", "hy2")
AEAD = {
    "aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
    "chacha20-poly1305", "xchacha20-ietf-poly1305", "xchacha20-poly1305",
}
# Хосты, с которых принимаем автоматически найденные подписки: публичная история изменений.
TRUSTED_HOSTS = {
    "raw.githubusercontent.com", "codeberg.org", "gitlab.com", "hub.mos.ru",
    "gitverse.ru", "cdn.jsdelivr.net", "bitbucket.org", "gitea.com",
}
MIN_SECURE = 3
MIN_FOUND_SECURE = 20
MIN_FOUND_SHARE = 0.6
FOUND_RECOMMENDED = 6
DEAD_AFTER_DAYS = 3
STALE_AFTER_DAYS = 10


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def parse_iso(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value)
    except ValueError:
        return None


def b64decode(text: str) -> str | None:
    clean = re.sub(r"\s+", "", text).replace("-", "+").replace("_", "/").rstrip("=")
    if not clean:
        return None
    clean += "=" * ((4 - len(clean) % 4) % 4)
    try:
        return base64.b64decode(clean).decode("utf-8")
    except Exception:  # noqa: BLE001
        return None


def fetch(url: str) -> tuple[int, bytes]:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:  # noqa: S310
        body = resp.read(MAX_BODY + 1)
        if len(body) > MAX_BODY:
            raise ValueError("больше 8 МБ")
        return resp.status, body


def query(link: str) -> dict[str, str]:
    q = link.split("#", 1)[0]
    q = q.split("?", 1)[1] if "?" in q else ""
    return {k.lower(): v for k, v in urllib.parse.parse_qsl(q, keep_blank_values=True)}


def endpoint(link: str, scheme: str) -> tuple[str, int] | None:
    body = link.split("://", 1)[1].split("#", 1)[0]
    if scheme == "vmess":
        payload = b64decode(body)
        if not payload:
            return None
        try:
            obj = json.loads(payload)
            return str(obj.get("add", "")).strip(), int(str(obj.get("port", "0")).strip() or 0)
        except Exception:  # noqa: BLE001
            return None
    main = body.split("?", 1)[0].rstrip("/")
    if scheme == "ss" and "@" not in main:
        decoded = b64decode(main)
        if not decoded or "@" not in decoded:
            return None
        main = decoded
    host_port = main.rsplit("@", 1)[-1]
    if host_port.startswith("["):
        end = host_port.find("]")
        host, port = host_port[1:end], host_port[end + 2:]
    else:
        host, _, port = host_port.rpartition(":")
    port = re.split(r"[,-]", port)[0]
    if not host or not port.isdigit():
        return None
    return host, int(port)


def insecure(link: str, scheme: str) -> bool:
    p = query(link)
    if (p.get("allowinsecure") == "1" or p.get("insecure") == "1") and not (p.get("pcs") or p.get("pinsha256")):
        return True
    sec = p.get("security", "").lower()
    if scheme == "vless" and sec in ("", "none"):
        return True
    if scheme == "trojan" and sec == "none":
        return True
    if scheme == "vmess":
        payload = b64decode(link.split("://", 1)[1].split("#", 1)[0]) or "{}"
        try:
            scy = str(json.loads(payload).get("scy", "")).lower()
        except Exception:  # noqa: BLE001
            scy = ""
        return scy in ("none", "zero")
    if scheme == "ss":
        main = link.split("://", 1)[1].split("#", 1)[0].split("?", 1)[0]
        cred = main.rsplit("@", 1)[0] if "@" in main else (b64decode(main) or "").rsplit("@", 1)[0]
        cred = b64decode(cred) if cred and ":" not in cred else cred
        method = (cred or "").split(":", 1)[0].lower()
        return method not in AEAD and not method.startswith("2022-blake3-")
    return False


def parse(body: bytes) -> dict:
    text = body.decode("utf-8", errors="replace").lstrip("﻿").strip()
    if "://" not in text:
        decoded = b64decode(text)
        if decoded and "://" in decoded:
            text = decoded
    protocols: dict[str, int] = {}
    seen: set[str] = set()
    secure: list[tuple[str, int]] = []
    total = 0
    for raw in text.splitlines():
        line = raw.strip()
        scheme = line.split("://", 1)[0].lower() if "://" in line else ""
        if scheme not in SCHEMES:
            continue
        ep = endpoint(line, scheme)
        if not ep or ep[0] in ("0.0.0.0", "127.0.0.1"):
            continue
        key = line.split("#", 1)[0]
        if key in seen:
            continue
        seen.add(key)
        total += 1
        name = "hysteria2" if scheme == "hy2" else scheme
        protocols[name] = protocols.get(name, 0) + 1
        if not insecure(line, scheme):
            secure.append(ep)
    secure_count = len(secure)
    secure = list(dict.fromkeys(secure))
    return {"nodes": total, "secure": secure_count, "protocols": protocols, "endpoints": secure}


def tcp_alive(endpoints: list[tuple[str, int]], sample: int = 40) -> float | None:
    if not endpoints:
        return None
    pick = random.sample(endpoints, min(sample, len(endpoints)))

    def ping(ep: tuple[str, int]) -> bool:
        try:
            with socket.create_connection(ep, timeout=3):
                return True
        except OSError:
            return False

    with cf.ThreadPoolExecutor(max_workers=40) as pool:
        ok = sum(pool.map(ping, pick))
    return round(ok / len(pick), 2)


def check(source: dict, tcp: bool) -> dict:
    result = {"status": "dead", "error": None, "nodes": 0, "secure": 0, "protocols": {}, "mirror": None,
              "hash": None, "alive": None}
    for url in source["mirrors"]:
        try:
            status, body = fetch(url)
            if status != 200:
                result["error"] = f"HTTP {status}"
                continue
            if body.lstrip()[:1] == b"<":
                result["error"] = "вместо подписки веб-страница"
                continue
            stats = parse(body)
            result.update({
                "status": "ok" if stats["secure"] >= MIN_SECURE else "empty",
                "error": None if stats["secure"] >= MIN_SECURE else "почти нет безопасных узлов",
                "nodes": stats["nodes"], "secure": stats["secure"], "protocols": stats["protocols"],
                "mirror": url, "hash": hashlib.sha256(body).hexdigest()[:16],
            })
            if tcp and stats["secure"]:
                result["alive"] = tcp_alive(stats["endpoints"])
            if result["status"] == "ok":
                return result
        except Exception as e:  # noqa: BLE001
            result["error"] = str(e)[:120] or e.__class__.__name__
    return result


def discover(meta: list[dict], known: set[str]) -> list[dict]:
    found: dict[str, dict] = {}
    for entry in meta:
        try:
            _, body = fetch(entry["url"])
        except Exception as e:  # noqa: BLE001
            print(f"  ! список {entry['url']}: {e}", file=sys.stderr)
            continue
        for line in body.decode("utf-8", errors="replace").splitlines():
            m = re.match(r"\s*(https://\S+)", line)
            if not m:
                continue
            url = m.group(1).replace("/refs/heads/", "/")
            host = urllib.parse.urlparse(url).hostname or ""
            if host not in TRUSTED_HOSTS or url in known:
                continue
            parts = urllib.parse.urlparse(url).path.strip("/").split("/")
            owner, repo = (parts + ["", ""])[:2]
            file = parts[-1]
            sid = "found-" + hashlib.sha1(url.encode()).hexdigest()[:10]
            label = line[m.end():].strip()
            found[url] = {
                "id": sid,
                "title": (f"{owner} · {file}" if host == "raw.githubusercontent.com" else f"{host} · {file}")[:48],
                "author": owner,
                "homepage": f"https://github.com/{owner}/{repo}" if host == "raw.githubusercontent.com" else url,
                "license": "не указана",
                "description": (f"Найден автоматически: {file}. " + (f"Пометка автора: {label}." if label else "")).strip(),
                "mode": entry.get("mode", "any"),
                "mirrors": [url],
                "origin": "found",
            }
    return list(found.values())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tcp", action="store_true", help="выборочный TCP-пинг узлов")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-discover", action="store_true")
    args = ap.parse_args()

    spec = json.load(open(SOURCES, encoding="utf-8"))
    previous = {}
    if os.path.exists(OUTPUT):
        previous = {s["id"]: s for s in json.load(open(OUTPUT, encoding="utf-8")).get("sources", [])}

    curated = [dict(s, origin="curated") for s in spec["sources"]]
    known = {u for s in curated for u in s["mirrors"]}
    # Ранее найденные источники держим, пока живы: так каталог не «мигает» между прогонами.
    kept = [p for p in previous.values() if p.get("origin") == "found"]
    known |= {u for s in kept for u in s["mirrors"]}
    found = [] if args.no_discover else discover(spec.get("discover", []), known)
    candidates = curated + [{k: p[k] for k in ("id", "title", "author", "homepage", "license", "description",
                                               "mode", "mirrors", "origin")} for p in kept] + found

    stamp = now_iso()
    out: list[dict] = []
    with cf.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda s: check(s, args.tcp), candidates))
    for source, res in zip(candidates, results):
        prev = previous.get(source["id"], {})
        changed = prev.get("changedAt") if prev.get("hash") == res["hash"] and res["hash"] else stamp
        failing = None if res["status"] == "ok" else (prev.get("failingSince") or stamp)
        entry = {
            **{k: source[k] for k in ("id", "title", "author", "homepage", "license", "description", "mode",
                                      "mirrors", "origin")},
            "status": res["status"],
            "error": res["error"],
            "nodes": res["nodes"],
            "secure": res["secure"],
            "protocols": res["protocols"],
            "alive": res["alive"],
            "hash": res["hash"],
            "checkedAt": stamp,
            "changedAt": changed if res["hash"] else prev.get("changedAt"),
            "failingSince": failing,
        }
        changed_at = parse_iso(entry["changedAt"])
        if changed_at and (dt.datetime.now(dt.timezone.utc) - changed_at).days >= STALE_AFTER_DAYS:
            entry["status"] = "stale"
        out.append(entry)

    # Найденные: оставляем только достаточно хорошие и не мёртвые дольше DEAD_AFTER_DAYS.
    def keep(e: dict) -> bool:
        if e["origin"] != "found":
            return True
        failing = parse_iso(e["failingSince"])
        if failing and (dt.datetime.now(dt.timezone.utc) - failing).days >= DEAD_AFTER_DAYS:
            return False
        if e["status"] == "ok":
            return e["secure"] >= MIN_FOUND_SECURE and e["secure"] / max(e["nodes"], 1) >= MIN_FOUND_SHARE
        return e["id"] in previous

    out = [e for e in out if keep(e)]
    ranked = sorted((e for e in out if e["origin"] == "found" and e["status"] == "ok"),
                    key=lambda e: (-(e["alive"] or 0.5), -min(e["secure"], 400)))
    top = {e["id"] for e in ranked[:FOUND_RECOMMENDED]}
    for e in out:
        e["recommended"] = (e["origin"] == "curated" and e["status"] in ("ok", "dead")) or e["id"] in top

    for e in out:
        mark = {"ok": "✓", "empty": "∅", "dead": "✗", "stale": "…"}[e["status"]]
        alive = f" живых≈{int(e['alive'] * 100)}%" if e["alive"] is not None else ""
        rec = " ★" if e["recommended"] else ""
        print(f"{mark} [{e['mode']:5}] {e['title'][:42]:42} узлов {e['nodes']:5} безопасных {e['secure']:5}"
              f"{alive}{rec} {e['error'] or ''}")

    if args.dry_run:
        return 0
    doc = {"version": 1, "generatedAt": stamp, "sources": out}
    for path in (OUTPUT, ASSET):
        if path == ASSET and not os.path.isdir(os.path.dirname(ASSET)):
            continue
        with open(path, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=1)
            f.write("\n")
    print(f"Записано {len(out)} источников")
    return 0


if __name__ == "__main__":
    sys.exit(main())
