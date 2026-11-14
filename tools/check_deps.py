#!/usr/bin/env python3
"""Следит за новыми версиями того, на чём собран «Лоцман», и заводит задачу (Issue) в репозитории —
GitHub присылает владельцу письмо и уведомление в приложении.

  check_deps.py [--dry-run]

Что проверяется (закреплённые версии — в tools/fetch_natives.sh):
  • Xray-core (XTLS/Xray-core) — ядро для Windows 10/11 и Windows 7;
  • AndroidLibXrayLite (2dust) — то же ядро для Android, выходит следом за Xray-core;
  • hev-socks5-tunnel (heiher) — TUN-мост на Android.
На каждую новую версию — одна задача; повторно не заводится (ищем по заголовку, в том числе среди закрытых).
"""
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.request

DRY = "--dry-run" in sys.argv
REPO = os.environ.get("GITHUB_REPOSITORY", "atomicpel/locman")
TOKEN = os.environ.get("GITHUB_TOKEN", "")
LABEL = "обновление-ядра"


def api(path, data=None):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "locman-deps"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request("https://api.github.com/" + path, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310
        return json.load(resp)


def sha256_of(url):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "locman-deps"})
        h = hashlib.sha256()
        with urllib.request.urlopen(req, timeout=120) as resp:  # noqa: S310
            while chunk := resp.read(1 << 20):
                h.update(chunk)
        return h.hexdigest()
    except Exception as e:  # noqa: BLE001
        return f"не скачался ({e})"


def key(v):
    return [int(x) for x in re.findall(r"\d+", v)]


script = pathlib.Path("tools/fetch_natives.sh").read_text(encoding="utf-8")
# DEPS_PRETEND_* — для проверки самого сторожа: «как будто закреплена старая версия».
xray_now = os.environ.get("DEPS_PRETEND_XRAY") or re.search(r"XRAY_LIB_VERSION:-(v[0-9.]+)", script).group(1)
hev_now = os.environ.get("DEPS_PRETEND_HEV") or re.search(r"HEV_VERSION:-([0-9.]+)", script).group(1)

found = []  # (заголовок, текст)

# --- Xray-core и его сборка для Android ---
core = api("repos/XTLS/Xray-core/releases/latest")  # без предварительных выпусков
lib = api("repos/2dust/AndroidLibXrayLite/releases/latest")
core_v, lib_v = core["tag_name"], lib["tag_name"]
print(f"Xray-core: закреплён {xray_now}, вышел {core_v}; для Android вышел {lib_v}")
if key(core_v) > key(xray_now):
    base = f"https://github.com/XTLS/Xray-core/releases/download/{core_v}"
    android_ready = key(lib_v) >= key(core_v)
    lines = [
        f"Вышло ядро **Xray-core {core_v}** — в «Лоцмане» сейчас {xray_now}.",
        "",
        f"Описание выпуска: {core['html_url']}",
        "",
        "Готовность по платформам:",
        f"- Windows 10/11 и Windows 7: можно обновлять (сборки `Xray-windows-64.zip` и `Xray-win7-64.zip` есть в выпуске).",
        f"- Android: {'можно обновлять — AndroidLibXrayLite ' + lib_v + ' вышла' if android_ready else 'пока нельзя — сборка ядра для Android (AndroidLibXrayLite) ещё на ' + lib_v + '; когда выйдет, сюда добавится комментарий'}.",
        "",
        "Контрольные суммы (SHA-256) — их нужно закрепить в `tools/*.sha256`:",
        f"- `Xray-windows-64.zip`: `{sha256_of(base + '/Xray-windows-64.zip')}`",
        f"- `Xray-win7-64.zip`: `{sha256_of(base + '/Xray-win7-64.zip')}`",
    ]
    aar_line = None
    if android_ready:
        aar = f"https://github.com/2dust/AndroidLibXrayLite/releases/download/{lib_v}/libv2ray.aar"
        aar_line = f"- `libv2ray.aar` ({lib_v}): `{sha256_of(aar)}`"
        lines.append(aar_line)
    lines += [
        "",
        "Что делать: попросите Claude «обнови ядро Xray до " + core_v + "» — он поменяет версию, закрепит суммы, "
        "проверит сборку и выпустит только те платформы, которые вы назовёте.",
        "",
        "<details><summary>Что изменилось в ядре</summary>",
        "",
        (core.get("body") or "")[:3000],
        "",
        "</details>",
    ]
    found.append((f"Вышло ядро Xray-core {core_v} (сейчас {xray_now})", "\n".join(lines), aar_line))

# --- TUN-мост для Android ---
hev = api("repos/heiher/hev-socks5-tunnel/releases/latest")
hev_v = hev["tag_name"]
print(f"hev-socks5-tunnel: закреплён {hev_now}, вышел {hev_v}")
if key(hev_v) > key(hev_now):
    commit = api(f"repos/heiher/hev-socks5-tunnel/commits/{hev_v}")["sha"]
    found.append((
        f"Вышел TUN-мост hev-socks5-tunnel {hev_v} (сейчас {hev_now})",
        "\n".join([
            f"Вышла новая версия TUN-моста для Android: **{hev_v}** — в «Лоцмане» сейчас {hev_now}.",
            "",
            f"Описание выпуска: {hev['html_url']}",
            f"Коммит тега (закрепляется в `tools/fetch_natives.sh`): `{commit}`",
            "",
            "Касается только Android. Обновлять стоит, если в описании есть исправления ошибок или безопасности.",
            "",
            (hev.get("body") or "")[:2000],
        ]),
        None,
    ))

if not found:
    print("Всё актуально")
    sys.exit(0)

existing = {} if DRY and not TOKEN else {
    i["title"]: i for i in api(f"repos/{REPO}/issues?state=all&labels={urllib.request.quote(LABEL)}&per_page=100")
    if "pull_request" not in i
}
owner = REPO.split("/")[0]
for title, body, aar_line in found:
    old = existing.get(title)
    if old is None:
        print(f"Новая задача: {title}")
        if DRY:
            print(body)
            continue
        api(f"repos/{REPO}/issues", {"title": title, "body": body, "labels": [LABEL], "assignees": [owner]})
    elif aar_line and "AndroidLibXrayLite) ещё на" in (old.get("body") or "") and old["state"] == "open":
        # Задача заведена раньше, чем вышла сборка для Android, — дописываем один раз.
        marker = "Сборка ядра для Android вышла"
        comments = api(f"repos/{REPO}/issues/{old['number']}/comments?per_page=100")
        if not any(marker in (c.get("body") or "") for c in comments):
            print(f"Комментарий: {marker}")
            if not DRY:
                api(f"repos/{REPO}/issues/{old['number']}/comments",
                    {"body": f"{marker} — теперь можно обновлять и Android.\n\nКонтрольная сумма (SHA-256):\n{aar_line}"})
    else:
        print(f"Уже есть: {title}")
