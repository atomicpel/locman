# Выпуски

Три программы — три отдельных канала. Счёт версий общий, но выпускается только то, что менялось.

| Платформа | Ветка выпуска | Метка выпуска | Заметки | Файл обновлений |
|---|---|---|---|---|
| Android | `release/android/vX.Y.Z` | `android-vX.Y.Z` | `release-notes/android.txt` | `update.json` |
| Windows 10/11 | `release/windows/vX.Y.Z` | `windows-vX.Y.Z` | `release-notes/windows.txt` | `update-windows.json` |
| Windows 7 (Lite) | `release/win7/vX.Y.Z` | `win7-vX.Y.Z` | `release-notes/win7.txt` | `update-win7.json` |

Порядок:
1. Правка и заметки своей платформы — в `main`; сборка `main` проверяет все три платформы, ничего не выпуская.
2. Ветка `release/<платформа>/vX.Y.Z` от `main` — собирается и выпускается только эта платформа.
3. Номер — следующий за последним выпущенным (у любой платформы). Общую правку для Android и
   Windows 10/11 можно выпустить двумя ветками под одним номером.

Файлы обновлений лежат в ветке `updates` и приложены к каждому выпуску. `update.json` читают Android и
все старые версии до разделения каналов (≤ 1.9.2); его номер меняется только при выпуске для Android.

Новые версии ядра: `tools/check_deps.py` (раз в сутки, `.github/workflows/deps.yml`) заводит задачу с меткой
«обновление-ядра», когда выходят Xray-core, AndroidLibXrayLite или hev-socks5-tunnel новее закреплённых.
