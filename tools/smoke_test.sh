#!/usr/bin/env bash
# Самопроверка «Лоцмана» в эмуляторе: установка, онбординг, поиск узла, туннель, снимки экрана.
#   smoke_test.sh APK OUT_DIR
# Каждый вызов adb — с таймаутом: если эмулятор подвиснет, проверка не повиснет вместе с ним.
set -u
APK="$1"; OUT="$2"; PKG=app.locman
mkdir -p "$OUT"
TRACE="$OUT/trace.txt"
A() {
  timeout "${T:-20}" adb "$@"; local rc=$?
  echo "$(date +%T) rc=$rc adb $*" | cut -c1-200 >> "$TRACE"
  return $rc
}

timeout 300 adb wait-for-device
timeout 300 adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done'
T=180 A install -r -g "$APK" || exit 1
A shell appops set $PKG ACTIVATE_VPN allow
A shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null || true

run() {   # run SKIN PREFIX TUN
  local skin="$1" prefix="$2" tun="$3" deadline=$((SECONDS + 480))
  local dir=/sdcard/Android/data/$PKG/files
  A shell am force-stop $PKG
  A shell rm -f "$dir/*.png" "$dir/smoke.txt"
  A logcat -c
  A shell am start -n $PKG/.MainActivity --ez smoke true --es skin "$skin" --es tun "$tun"
  # Пока поднят VPN, adb в эмуляторе может не отвечать — опрашиваем редко и с таймаутом.
  while [ $SECONDS -lt $deadline ]; do
    sleep 15
    echo "$(date +%T) devices: $(timeout 10 adb devices | tr '\n' ' ')" >> "$TRACE"
    if A shell cat "$dir/smoke.txt" > "$OUT/tmp.txt" 2>/dev/null && [ -s "$OUT/tmp.txt" ]; then
      mv "$OUT/tmp.txt" "$OUT/$prefix-log.txt"
    fi
    grep -aq 'SMOKE: done\|SMOKE: error' "$OUT/$prefix-log.txt" 2>/dev/null && break
  done
  sleep 5
  for f in $(A shell ls "$dir" 2>/dev/null | tr -d '\r' | grep '\.png$'); do
    T=40 A pull "$dir/$f" "$OUT/$f" > /dev/null 2>&1 || true
  done
  echo "== $prefix"
  cat "$OUT/$prefix-log.txt" 2>/dev/null
  T=40 A logcat -d -t 4000 > "$OUT/$prefix-logcat.txt" 2>/dev/null || true
}

run glass glass xray
run island island hev
grep -aq 'SMOKE: probe true' "$OUT/glass-log.txt" && grep -aq 'SMOKE: probe true' "$OUT/island-log.txt"
