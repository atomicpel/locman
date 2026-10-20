#!/usr/bin/env bash
# Самопроверка «Лоцмана» в эмуляторе: установка, онбординг, поиск узла, туннель, снимки экрана.
#   smoke_test.sh APK OUT_DIR
# Каждый вызов adb — с таймаутом: если эмулятор подвиснет, проверка не повиснет вместе с ним.
set -u
APK="$1"; OUT="$2"; PKG=app.locman
mkdir -p "$OUT"
A() { timeout "${T:-20}" adb "$@"; }

timeout 300 adb wait-for-device
timeout 300 adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done'
T=180 A install -r -g "$APK" || exit 1
A shell appops set $PKG ACTIVATE_VPN allow
A shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null || true

run() {   # run SKIN PREFIX TUN
  local skin="$1" prefix="$2" tun="$3" seen="" deadline=$((SECONDS + 360))
  A shell am force-stop $PKG
  A logcat -c
  A shell am start -n $PKG/.MainActivity --ez smoke true --es skin "$skin" --es tun "$tun"
  while [ $SECONDS -lt $deadline ]; do
    if A logcat -d -s flutter:I > "$OUT/tmp.txt" 2>/dev/null && [ -s "$OUT/tmp.txt" ]; then
      mv "$OUT/tmp.txt" "$OUT/$prefix-log.txt"
    fi
    for shot in $(grep -ao 'SMOKE: shot [a-z-]*' "$OUT/$prefix-log.txt" 2>/dev/null | awk '{print $3}'); do
      case " $seen " in *" $shot "*) ;; *)
        A exec-out screencap -p > "$OUT/$prefix-$shot.png" && seen="$seen $shot";;
      esac
    done
    grep -aq 'SMOKE: done\|SMOKE: error' "$OUT/$prefix-log.txt" 2>/dev/null && break
    sleep 3
  done
  grep -a 'SMOKE:' "$OUT/$prefix-log.txt" 2>/dev/null | sed 's/.*SMOKE:/SMOKE:/'
  A shell dumpsys connectivity 2>/dev/null | grep -i -m5 'VPN' > "$OUT/$prefix-vpn.txt" || true
  T=40 A logcat -d -t 3000 > "$OUT/$prefix-logcat.txt" 2>/dev/null || true
}

run glass glass xray
run island island hev
grep -aq 'SMOKE: probe true' "$OUT/glass-log.txt" && grep -aq 'SMOKE: probe true' "$OUT/island-log.txt"
