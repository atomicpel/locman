#!/usr/bin/env python3
"""Обновить закреплённые версии ядра и TUN-моста: версии в tools/fetch_natives.sh и контрольные суммы.

  bump_core.py [--xray vX.Y.Z] [--hev X.Y.Z]

Суммы сборок Xray для Windows сверяются с официальными файлами .dgst из выпуска Xray-core;
libv2ray.aar (Android) — с суммой, которую публикует GitHub для файла выпуска.
Коммит тега hev-socks5-tunnel закрепляется по git ls-remote.
Печатает, что поменялось; при ошибке — выходит с кодом 1, ничего не меняя.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.request

UA = {"User-Agent": "locman-bump"}


def fetch(url, binary=True):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=300) as resp:  # noqa: S310
        data = resp.read()
    return data if binary else data.decode()


def sha(url):
    return hashlib.sha256(fetch(url)).hexdigest()


def dgst(url):
    m = re.search(r"SHA2-256=\s*([0-9a-f]{64})", fetch(url + ".dgst", binary=False))
    if not m:
        raise SystemExit(f"нет SHA2-256 в {url}.dgst")
    return m.group(1)


def github_digest(repo, tag, name):
    """Сумма, которую GitHub считает сам при загрузке файла выпуска (поле digest)."""
    headers = dict(UA, Accept="application/vnd.github+json")
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/tags/{tag}", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310
            rel = json.load(resp)
        for a in rel.get("assets", []):
            if a["name"] == name and str(a.get("digest", "")).startswith("sha256:"):
                return a["digest"].split(":", 1)[1]
    except Exception:  # noqa: BLE001
        pass
    return None


ap = argparse.ArgumentParser()
ap.add_argument("--xray")
ap.add_argument("--hev")
args = ap.parse_args()

script_path = pathlib.Path("tools/fetch_natives.sh")
script = script_path.read_text(encoding="utf-8")
changes = []
writes = {}

if args.xray:
    v = args.xray if args.xray.startswith("v") else "v" + args.xray
    base = f"https://github.com/XTLS/Xray-core/releases/download/{v}"
    win = sha(base + "/Xray-windows-64.zip")
    win7 = sha(base + "/Xray-win7-64.zip")
    if win != dgst(base + "/Xray-windows-64.zip") or win7 != dgst(base + "/Xray-win7-64.zip"):
        raise SystemExit("Сборки Xray для Windows не совпали с официальными суммами .dgst")
    aar_url = f"https://github.com/2dust/AndroidLibXrayLite/releases/download/{v}/libv2ray.aar"
    aar = sha(aar_url)
    published = github_digest("2dust/AndroidLibXrayLite", v, "libv2ray.aar")
    if published and published != aar:
        raise SystemExit("libv2ray.aar не совпал с суммой, опубликованной GitHub")
    script = re.sub(r'XRAY_LIB_VERSION:-v[0-9.]+', f"XRAY_LIB_VERSION:-{v}", script)
    writes["tools/natives.sha256"] = f"{aar}  android/app/libs/libv2ray.aar\n"
    writes["tools/xray-windows.sha256"] = f"{win}  xray-win/xray.zip\n"
    writes["tools/xray-win7.sha256"] = f"{win7}  xray-win7/xray.zip\n"
    changes.append(f"xray {v}")

if args.hev:
    v = args.hev
    out = subprocess.run(["git", "ls-remote", "https://github.com/heiher/hev-socks5-tunnel", f"refs/tags/{v}"],
                         capture_output=True, text=True, check=True).stdout.split()
    if not out:
        raise SystemExit(f"нет тега hev-socks5-tunnel {v}")
    script = re.sub(r'HEV_VERSION:-[0-9.]+', f"HEV_VERSION:-{v}", script)
    script = re.sub(r'HEV_COMMIT="[0-9a-f]{40}"', f'HEV_COMMIT="{out[0]}"', script)
    changes.append(f"hev {v} ({out[0][:10]})")

script_path.write_text(script, encoding="utf-8")
for path, text in writes.items():
    pathlib.Path(path).write_text(text, encoding="utf-8")
print("; ".join(changes) or "ничего")
