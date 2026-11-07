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
    "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
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
# Сколько найденных источников держим в каталоге (лучшие по живости и числу безопасных узлов).
MAX_FOUND = 30

# Поиск по GitHub: репозитории с подписками, обновлённые за последние дни.
GITHUB_QUERIES = [
    "vless reality russia",
    "vpn configs russia",
    "white list vless",
    "белые списки vless",
    "vless russia subscription",
    "v2ray configs collector",
    "topic:v2ray-config",
    "topic:vless",
]
GITHUB_FRESH_DAYS = 3
GITHUB_MAX_REPOS = 40
GITHUB_FILES_PER_REPO = 4
# Имена файлов, похожие на подписки.
SUB_NAME = re.compile(r"(sub|vless|config|white|black|wl|bl|mix|all|rus|reality|v2ray|base64|merged|nodes|bypass|keys)",
                      re.I)
SKIP_NAME = re.compile(r"(readme|license|requirements|changelog|robots|\.github/|test|example)", re.I)
RU_HINT = re.compile(r"(russia|росси|rus\b|\bru\b|white|бел|wl\b|ркн|rkn)", re.I)
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
    # Отпечаток содержимого: одинаковые наборы ключей (в т. ч. base64 и обычный текст) — один источник.
    khash = hashlib.sha256("\n".join(sorted(seen)).encode()).hexdigest()[:16] if seen else None
    return {"nodes": total, "secure": secure_count, "protocols": protocols, "endpoints": secure, "khash": khash}


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
              "hash": None, "alive": None, "khash": None}
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
                "mirror": url, "hash": hashlib.sha256(body).hexdigest()[:16], "khash": stats["khash"],
            })
            if tcp and stats["secure"]:
                result["alive"] = tcp_alive(stats["endpoints"])
            if result["status"] == "ok":
                return result
        except Exception as e:  # noqa: BLE001
            result["error"] = str(e)[:120] or e.__class__.__name__
    return result


def gh_api(path: str, token: str) -> dict:
    req = urllib.request.Request("https://api.github.com/" + path, headers={
        "User-Agent": UA, "Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
    })
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:  # noqa: S310
        return json.loads(resp.read(MAX_BODY))


def mode_of(text: str) -> str:
    t = text.lower()
    if re.search(r"(white|бел|(?:^|[^a-z])wl(?:[^a-z]|$)|bypass)", t):
        return "white"
    if re.search(r"(black|(?:^|[^a-z])bl(?:[^a-z]|$))", t):
        return "black"
    return "any"


def search_github(known: set[str]) -> list[dict]:
    """Второй механизм поиска: GitHub. Ищем репозитории, обновлённые за последние дни, и берём из них
    файлы, похожие на подписки. Дальше они проходят ту же проверку, что и остальные найденные:
    достаточно безопасных узлов, живость по TCP, не мёртвые дольше трёх дней."""
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        print("  · поиск по GitHub пропущен: нет GITHUB_TOKEN", file=sys.stderr)
        return []
    since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=GITHUB_FRESH_DAYS)).strftime("%Y-%m-%d")
    repos: dict[str, dict] = {}
    for q in GITHUB_QUERIES:
        try:
            res = gh_api("search/repositories?" + urllib.parse.urlencode(
                {"q": f"{q} pushed:>{since}", "sort": "updated", "per_page": 30}), token)
        except Exception as e:  # noqa: BLE001
            print(f"  ! поиск «{q}»: {e}", file=sys.stderr)
            continue
        for item in res.get("items", []):
            if item.get("fork") or item.get("archived") or item.get("size", 0) > 500_000:
                continue
            repos.setdefault(item["full_name"], item)
    # Сначала те, что явно про Россию и белые списки.
    ranked = sorted(repos.values(), key=lambda r: (
        not RU_HINT.search(f"{r['full_name']} {r.get('description') or ''} {' '.join(r.get('topics') or [])}"),
        -(r.get("stargazers_count") or 0)))[:GITHUB_MAX_REPOS]
    found: list[dict] = []
    for repo in ranked:
        full, branch = repo["full_name"], repo.get("default_branch") or "main"
        try:
            tree = gh_api(f"repos/{full}/git/trees/{urllib.parse.quote(branch)}?recursive=1", token)
        except Exception as e:  # noqa: BLE001
            print(f"  ! {full}: {e}", file=sys.stderr)
            continue
        files = [t for t in tree.get("tree", [])
                 if t.get("type") == "blob" and 2_000 < (t.get("size") or 0) < MAX_BODY
                 and t["path"].count("/") <= 3 and SUB_NAME.search(t["path"]) and not SKIP_NAME.search(t["path"])
                 and (t["path"].endswith(".txt") or "." not in t["path"].rsplit("/", 1)[-1])]
        files.sort(key=lambda t: (not RU_HINT.search(t["path"]), -(t.get("size") or 0)))
        owner, name = full.split("/", 1)
        for t in files[:GITHUB_FILES_PER_REPO]:
            path = urllib.parse.quote(t["path"])
            raw = f"https://raw.githubusercontent.com/{full}/{branch}/{path}"
            if raw in known:
                continue
            file = t["path"].rsplit("/", 1)[-1]
            found.append({
                "id": "found-" + hashlib.sha1(raw.encode()).hexdigest()[:10],
                "title": f"{owner} · {file}"[:48],
                "author": owner,
                "homepage": f"https://github.com/{full}",
                "license": (repo.get("license") or {}).get("spdx_id") or "не указана",
                "description": f"Найден поиском по GitHub: {file}. " + ((repo.get("description") or "")[:120]),
                "mode": mode_of(t["path"]) if mode_of(t["path"]) != "any" else mode_of(name),
                # jsDelivr — запасной адрес, когда GitHub недоступен
                "mirrors": [raw, f"https://cdn.jsdelivr.net/gh/{full}@{branch}/{path}"],
                "origin": "found",
            })
    print(f"  · GitHub: репозиториев {len(ranked)}, файлов-кандидатов {len(found)}", file=sys.stderr)
    return found


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
    for p in kept:
        # Режим найденных поиском по GitHub — только по пути файла и имени репозитория.
        if p.get("description", "").startswith("Найден поиском по GitHub") and p.get("mirrors"):
            parts = urllib.parse.urlparse(p["mirrors"][0]).path.strip("/").split("/")
            path = "/".join(parts[3:])
            p["mode"] = mode_of(path) if mode_of(path) != "any" else mode_of(parts[1] if len(parts) > 1 else "")
    known |= {u for s in kept for u in s["mirrors"]}
    found = [] if args.no_discover else discover(spec.get("discover", []), known)
    if not args.no_discover:
        known |= {u for s in found for u in s["mirrors"]}
        found += search_github(known)
    candidates = curated + [{k: p[k] for k in ("id", "title", "author", "homepage", "license", "description",
                                               "mode", "mirrors", "origin")} for p in kept] + found

    stamp = now_iso()
    out: list[dict] = []
    with cf.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda s: check(s, args.tcp), candidates))
    by_id = {source["id"]: res for source, res in zip(candidates, results)}
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
    # Одинаковое содержимое (копии, base64-варианты, файлы курируемых источников) — оставляем первый,
    # курируемые идут раньше найденных.
    seen_k: set[str] = set()
    deduped = []
    for e, res in sorted(((e, by_id[e["id"]]) for e in out), key=lambda x: x[0]["origin"] != "curated"):
        k = res.get("khash")
        if e["origin"] == "found" and k and k in seen_k:
            continue
        if k:
            seen_k.add(k)
        deduped.append(e)
    order = {e["id"]: i for i, e in enumerate(out)}
    out = sorted(deduped, key=lambda e: order[e["id"]])

    def ru(e: dict) -> bool:
        return bool(RU_HINT.search(f"{e['homepage']} {e['title']} {e['description']}")) or e["mode"] != "any"

    # Найденных не больше MAX_FOUND и не больше двух файлов из одного репозитория; про Россию — первыми.
    found_ok = sorted((e for e in out if e["origin"] == "found"),
                      key=lambda e: (e["status"] != "ok", not ru(e), -(e["alive"] or 0.5), -min(e["secure"], 400)))
    per_repo: dict[str, int] = {}
    keep_ids = set()
    for e in found_ok:
        if len(keep_ids) >= MAX_FOUND or per_repo.get(e["homepage"], 0) >= 2:
            continue
        per_repo[e["homepage"]] = per_repo.get(e["homepage"], 0) + 1
        keep_ids.add(e["id"])
    out = [e for e in out if e["origin"] != "found" or e["id"] in keep_ids]
    # Включёнными по умолчанию становятся только найденные источники про Россию.
    ranked = sorted((e for e in out if e["origin"] == "found" and e["status"] == "ok" and ru(e)),
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
