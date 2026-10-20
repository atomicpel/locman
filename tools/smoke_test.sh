#!/usr/bin/env bash
# Самопроверка «Лоцмана» в эмуляторе: установка, онбординг, поиск узла, туннель, снимки экрана.
#   smoke_test.sh APK OUT_DIR
set -u
APK="$1"; OUT="$2"; PKG=app.locman
mkdir -p "$OUT"
adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done'
adb install -r -g "$APK" || exit 1
adb shell appops set $PKG ACTIVATE_VPN allow
adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null || true
adb logcat -c

run() {   # run SKIN PREFIX TUN
  local skin="$1" prefix="$2" tun="$3"
  adb shell am force-stop $PKG
  adb logcat -c
  adb shell am start -n $PKG/.MainActivity --ez smoke true --es skin "$skin" --es tun "$tun"
  local deadline=$((SECONDS + 420)) seen=""
  while [ $SECONDS -lt $deadline ]; do
    adb logcat -d -s flutter:I > "$OUT/$prefix-log.txt" 2>/dev/null
    for shot in $(grep -o 'SMOKE: shot [a-z-]*' "$OUT/$prefix-log.txt" | awk '{print $3}'); do
      case " $seen " in *" $shot "*) ;; *)
        adb exec-out screencap -p > "$OUT/$prefix-$shot.png"; seen="$seen $shot";;
      esac
    done
    grep -q 'SMOKE: done\|SMOKE: error' "$OUT/$prefix-log.txt" && break
    sleep 2
  done
  grep 'SMOKE:' "$OUT/$prefix-log.txt"
}

run glass glass xray
adb shell dumpsys connectivity | grep -i -m5 'VPN' > "$OUT/vpn.txt" || true
adb logcat -d > "$OUT/logcat-full.txt"
run island island hev
run paper paper xray
grep -q 'SMOKE: probe true' "$OUT/glass-log.txt" && grep -q 'SMOKE: probe true' "$OUT/island-log.txt"
