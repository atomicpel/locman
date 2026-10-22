#!/usr/bin/env python3
"""Дописывает в assets/changelog.json версию, которая сейчас собирается (из release-notes.txt),
если её там ещё нет. История изменений внутри приложения работает без интернета.
   changelog.py VERSION
"""
import datetime
import json
import pathlib
import sys

version = sys.argv[1]
path = pathlib.Path("assets/changelog.json")
log = json.loads(path.read_text(encoding="utf-8")) if path.exists() else []
if version.startswith("0.0.") or any(e.get("version") == version for e in log):
    sys.exit(0)
notes = [l.strip() for l in pathlib.Path("release-notes.txt").read_text(encoding="utf-8").splitlines() if l.strip()]
msk = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=3)))
log.insert(0, {"version": version, "date": msk.strftime("%d.%m.%Y"), "notes": notes})
path.write_text(json.dumps(log, ensure_ascii=False, indent=1), encoding="utf-8")
print(f"changelog: добавлена {version}")
