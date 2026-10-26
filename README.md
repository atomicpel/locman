# Лоцман

VPN-клиент для Android и Windows 10/11 на ядре Xray. Одна кнопка — рабочий узел находится сам.

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

### Windows 10/11

Скачайте `Locman-X.Y.Z-windows-x64-setup.exe` (ставится в профиль пользователя, права администратора не нужны)
или `Locman-X.Y.Z-windows-x64-portable.zip` (распаковать и запустить `locman.exe`).
Подписи кода нет, поэтому SmartScreen при первом запуске покажет «Неизвестный издатель» — «Подробнее → Выполнить в любом случае».

- **Системный прокси** (по умолчанию): через узел идут браузеры и программы, которые берут прокси Windows;
  для остальных — HTTP `127.0.0.1:10809` и SOCKS5 `127.0.0.1:10808`.
- **TUN**: весь трафик компьютера через адаптер Wintun; «Лоцман» попросит перезапуститься от имени администратора.
- Значок у часов: открыть, подключить/отключить, выход. Крестик прячет окно туда же.
- Автозапуск с Windows, ссылки `locman://import` из браузера и мессенджеров, обновления из релизов.

Ядро — официальный `xray.exe` из [Xray-core](https://github.com/XTLS/Xray-core) (Wintun — от WireGuard).

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

## Условия и данные

[Условия использования](assets/legal/terms.md) и [политика конфиденциальности](assets/legal/privacy.md) — те же тексты, что открываются в приложении («Ещё → О клиенте»).

## Благодарности и лицензия

Схема движка, разборщик ссылок и каталог основаны на [Farvater](https://github.com/farvater-app/farvater) (GPL-3.0),
поэтому «Лоцман» тоже под GPL-3.0. Xray-core — MPL-2.0, hev-socks5-tunnel — MIT, шрифты Manrope и Literata — OFL.
