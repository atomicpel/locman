#!/usr/bin/env python3
"""Файлы проверки обновлений — у каждой платформы свой, чтобы выпуск для одной не будил остальные.

  make_update_json.py PLATFORM VERSION CODE REPO TAG NOTES_FILE PREV_DIR OUT_DIR ФАЙЛ_УСТАНОВКИ

PLATFORM: android | windows | win7.
  update.json          — Android (его читают и все старые версии до разделения каналов)
  update-windows.json  — Windows 10/11
  update-win7.json     — Windows 7 (Лоцман Lite)
В PREV_DIR лежат текущие файлы из ветки updates; меняется только файл своей платформы.
В update.json, кроме того, обновляется ссылка на установщик платформы: старые версии для Windows,
которые ещё читают общий файл, при следующем выпуске для Android получат свежую сборку и
перейдут на свой канал.
"""
import datetime
import hashlib
import json
import os
import sys

platform, version, code, repo, tag, notes_file, prev_dir, out_dir, asset_file = sys.argv[1:]
KEYS = {"android": "arm64-v8a", "windows": "windows-x64", "win7": "win7-x64"}
FILES = {"android": "update.json", "windows": "update-windows.json", "win7": "update-win7.json"}
key = KEYS[platform]

notes = []
if os.path.exists(notes_file):
    notes = [l.strip().lstrip("-• ").strip() for l in open(notes_file, encoding="utf-8") if l.strip()]

data = open(asset_file, "rb").read()
asset = {
    "url": f"https://github.com/{repo}/releases/download/{tag}/{os.path.basename(asset_file)}",
    "sha256": hashlib.sha256(data).hexdigest(),
    "size": len(data),
}
head = {
    "versionCode": int(code),
    "versionName": version,
    "published": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
    "notes": notes,
}


def load(name):
    try:
        return json.load(open(os.path.join(prev_dir, name), encoding="utf-8"))
    except (OSError, ValueError):
        return None


os.makedirs(out_dir, exist_ok=True)
out = {name: load(name) for name in FILES.values()}
legacy = out["update.json"] or {**head, "assets": {}}
legacy.setdefault("assets", {})[key] = asset
if platform == "android":
    legacy.update(head)
else:
    out[FILES[platform]] = {**head, "assets": {key: asset}}
out["update.json"] = legacy
for name, content in out.items():
    if content is None:
        continue
    with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
        json.dump(content, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"{name}: {content['versionName']} ({', '.join(content['assets'])})", file=sys.stderr)
