# Лоцман

VPN-клиент для Android на ядре Xray. Одна кнопка — рабочий узел находится сам.

- **Протоколы:** VLESS (Reality, XHTTP, WS, gRPC, HTTPUpgrade, TLS), VMess, Trojan, Shadowsocks (AEAD, 2022), Hysteria2.
- **Режимы сети:** Авто (сам понимает, белые списки сейчас или обычные блокировки), БС, ЧС.
- **Свои сервисы напрямую:** банки, Госуслуги, Яндекс, VK, маркетплейсы идут мимо узла.
- **Каталог открытых подписок** проверяется в GitHub Actions раз в 6 часов (`catalog/catalog.json`); приложение подтягивает его само, новые живые источники появляются без обновления APK.
- **Свои источники:** ссылка подписки или ключи `vless://`, `vmess://`, `trojan://`, `ss://`, `hy2://` — хранятся только на телефоне.
- **Обновления** — из релизов этого репозитория, с проверкой SHA-256 и подписи.
- Пять обликов: Стекло, Чернила, Точка, Сигнал, Остров.

## Установка

Скачайте `Locman-X.Y.Z-arm64-v8a.apk` из [Releases](https://github.com/atomicpel/locman/releases/latest) и установите.
На Xiaomi/Poco (HyperOS) в «Ещё → Подключение» разрешите работу в фоне и автозапуск, иначе система может выключать VPN.

## Как устроено

```
Flutter (lib/)            экраны, подписки, выбор узла, конфиг Xray
   │ MethodChannel
Kotlin (android/app/…)    VpnService → TUN → hev-socks5-tunnel → SOCKS5 → Xray-core → узел
```

Сборка — только в GitHub Actions (`.github/workflows/build.yml`): `flutter create` дополняет платформенные файлы,
`tools/patch_android.py` настраивает Gradle, `tools/fetch_natives.sh` кладёт ядро Xray
([AndroidLibXrayLite](https://github.com/2dust/AndroidLibXrayLite)) и [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel).
Релиз — ветка `release/vX.Y.Z` (или тег `vX.Y.Z`): CI подпишет APK, создаст тег, релиз и `update.json`.

## Благодарности и лицензия

Схема движка, разборщик ссылок и каталог основаны на [Farvater](https://github.com/farvater-app/farvater) (GPL-3.0),
поэтому «Лоцман» тоже под GPL-3.0. Xray-core — MPL-2.0, hev-socks5-tunnel — MIT, шрифты Manrope и Literata — OFL.
