#!/usr/bin/env bash
# Версия сборки и платформа выпуска — общие для всех заданий CI (source tools/ci_version.sh).
# Выпуск — ветка release/<android|windows|win7>/vX.Y.Z: собирается и выпускается только эта платформа.
# Счёт версий общий: следующий выпуск любой платформы берёт следующий номер.
_ref="${GITHUB_REF#refs/heads/}"
if [[ "$_ref" =~ ^release/(android|windows|win7)/v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  PLATFORM="${BASH_REMATCH[1]}"
  VERSION="${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
  CODE=$((BASH_REMATCH[2] * 10000 + BASH_REMATCH[3] * 100 + BASH_REMATCH[4]))
  TAG="$PLATFORM-v$VERSION"
  RELEASE=1
else
  PLATFORM=all
  VERSION="0.0.${GITHUB_RUN_NUMBER:-0}"
  CODE="${GITHUB_RUN_NUMBER:-0}"
  TAG=""
  RELEASE=""
fi
export PLATFORM VERSION CODE TAG RELEASE
if [ -n "${GITHUB_ENV:-}" ]; then
  { echo "PLATFORM=$PLATFORM"; echo "VERSION=$VERSION"; echo "CODE=$CODE"; echo "TAG=$TAG"; echo "RELEASE=$RELEASE"; } >> "$GITHUB_ENV"
fi
