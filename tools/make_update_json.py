#!/usr/bin/env python3
"""update.json для проверки обновлений в приложении.

  make_update_json.py VERSION VERSION_CODE REPO TAG NOTES_FILE APK|SETUP.EXE...
"""
import datetime
import hashlib
import json
import os
import sys

version, code, repo, tag, notes_file, *apks = sys.argv[1:]
notes = []
if os.path.exists(notes_file):
    notes = [l.strip().lstrip("-• ").strip() for l in open(notes_file, encoding="utf-8") if l.strip()]

assets = {}
for apk in apks:
    name = os.path.basename(apk)
    if "windows" in name:
        abi = "windows-x64"
    else:
        abi = "arm64-v8a" if "arm64" in name else ("armeabi-v7a" if "armeabi" in name else "universal")
    data = open(apk, "rb").read()
    assets[abi] = {
        "url": f"https://github.com/{repo}/releases/download/{tag}/{name}",
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
    }

json.dump({
    "versionCode": int(code),
    "versionName": version,
    "published": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
    "notes": notes,
    "assets": assets,
}, sys.stdout, ensure_ascii=False, indent=1)
print()
