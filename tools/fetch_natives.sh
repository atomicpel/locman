#!/usr/bin/env bash
# Ядро Xray (libv2ray.aar из AndroidLibXrayLite) и TUN-мост hev-socks5-tunnel.
# Те же версии и патч, что у Farvater.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ABIS="${ABIS:-arm64-v8a}"
XRAY_LIB_VERSION="${XRAY_LIB_VERSION:-v26.10.10}"
HEV_VERSION="${HEV_VERSION:-2.18.0}"

echo "Ядро Xray ($XRAY_LIB_VERSION)"
mkdir -p "$ROOT/android/app/libs"
gh release download "$XRAY_LIB_VERSION" -R 2dust/AndroidLibXrayLite -p 'libv2ray.aar' -D "$ROOT/android/app/libs" --clobber

echo "TUN-мост (hev-socks5-tunnel $HEV_VERSION)"
WORK="$(mktemp -d)"
git clone --depth 1 --branch "$HEV_VERSION" --recursive --shallow-submodules \
  https://github.com/heiher/hev-socks5-tunnel "$WORK/jni"
patch -p1 -d "$WORK/jni" < "$ROOT/tools/hev-udp-bind.patch"
(
  cd "$WORK"
  "$ANDROID_NDK_HOME/ndk-build" \
    APP_ABI="$ABIS" \
    APP_PLATFORM=android-26 \
    APP_CFLAGS="-O3 -DPKGNAME=hev/sockstun -DCLSNAME=TProxyService" \
    APP_SUPPORT_FLEXIBLE_PAGE_SIZES=true
)
mkdir -p "$ROOT/android/app/src/main/jniLibs"
cp -r "$WORK/libs/"* "$ROOT/android/app/src/main/jniLibs/"
find "$ROOT/android/app/src/main/jniLibs" -name '*.so'
echo "Готово"
