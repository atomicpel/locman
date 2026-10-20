#!/usr/bin/env python3
"""Дописывает в android/app/build.gradle.kts (его создаёт `flutter create` в CI) то,
что нужно «Лоцману»: minSdk 26, подпись релиза, ядро Xray (.aar), androidx.core,
правила R8 и свои ресурсы (значок, иконка уведомления, file_paths).

Gradle-файл не хранится в репозитории, чтобы всегда совпадать с версией Flutter;
если шаблон изменится, скрипт громко упадёт.
"""
import os
import pathlib
import re
import shutil
import sys

# Свои ресурсы поверх сгенерированных
overlay = pathlib.Path("android/res-overlay")
res = pathlib.Path("android/app/src/main/res")
for src in overlay.rglob("*"):
    if src.is_file():
        dst = res / src.relative_to(overlay)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)

# Стандартный PNG-значок Flutter не нужен: на Android 8+ работает адаптивный из overlay.
for png in res.glob("mipmap-*/ic_launcher.png"):
    png.unlink()

path = pathlib.Path("android/app/build.gradle.kts")
text = path.read_text(encoding="utf-8")
if "libv2ray" in text or "LOCMAN_KEYSTORE" in text:
    print("patch_android: уже применён")
    sys.exit(0)


def replace(pattern: str, repl: str, what: str) -> None:
    global text
    text, n = re.subn(pattern, repl, text, count=1)
    if n != 1:
        sys.exit(f"patch_android: не нашёл «{what}» в {path} — шаблон Flutter изменился")


replace(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 26", "minSdk = flutter.minSdkVersion")

# Только arm64-v8a: Poco X7 Pro и почти все телефоны последних лет. Так APK в разы меньше,
# а versionCode не умножается на номер ABI, как при --split-per-abi.
replace(
    r"(defaultConfig\s*\{)",
    r"""\1
        ndk {
            abiFilters.clear()
            abiFilters.add("@ABI@")
        }""",
    "defaultConfig {",
)

replace(
    r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
    'signingConfig = if (System.getenv("LOCMAN_KEYSTORE") != null) '
    'signingConfigs.getByName("release") else signingConfigs.getByName("debug")\n'
    '            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")',
    'signingConfig = signingConfigs.getByName("debug")',
)

replace(
    r"(\nandroid\s*\{)",
    r"""\1
    signingConfigs {
        create("release") {
            val keystore = System.getenv("LOCMAN_KEYSTORE")
            if (keystore != null) {
                storeFile = file(keystore)
                storePassword = System.getenv("LOCMAN_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("LOCMAN_KEY_ALIAS") ?: "locman"
                keyPassword = System.getenv("LOCMAN_KEY_PASSWORD") ?: System.getenv("LOCMAN_KEYSTORE_PASSWORD")
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
""",
    "android {",
)

# arm64-v8a для телефона; x86_64 — только для проверки в эмуляторе CI.
ABI = os.environ.get("TARGET_ABI", "arm64-v8a")
if ABI not in ("arm64-v8a", "x86_64"):
    sys.exit(f"patch_android: неизвестный TARGET_ABI {ABI}")
text = text.replace("@ABI@", ABI)

text = text.rstrip("\n") + """

dependencies {
    // Ядро Xray (AndroidLibXrayLite) — скачивается в CI скриптом tools/fetch_natives.sh
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar", "*.jar"))))
    implementation("androidx.core:core:1.13.1")
}
"""

path.write_text(text, encoding="utf-8")

# Иначе Flutter Gradle plugin перезапишет наш фильтр ABI
props = pathlib.Path("android/gradle.properties")
props_text = props.read_text(encoding="utf-8") if props.exists() else ""
if "disable-abi-filtering" not in props_text:
    props.write_text(props_text.rstrip("\n") + "\ndisable-abi-filtering=true\n", encoding="utf-8")

print("patch_android: готово")
print(text)
