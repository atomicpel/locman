#!/usr/bin/env python3
"""Дописывает в windows/ (его создаёт `flutter create --platforms windows` в CI) то,
что нужно «Лоцману»: нативную часть locman_win.cpp, значок, заголовок и размер окна,
один экземпляр, запуск свёрнутым к часам.

Файлы раннера не хранятся в репозитории, чтобы всегда совпадать с версией Flutter;
если шаблон изменится, скрипт громко упадёт.
"""
import pathlib
import re
import shutil
import sys

overlay = pathlib.Path("windows-overlay")
win = pathlib.Path("windows")
for src in overlay.rglob("*"):
    if src.is_file():
        dst = win / src.relative_to(overlay)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)


def patch(path, pattern, repl, what, flags=0):
    p = pathlib.Path(path)
    text = p.read_text(encoding="utf-8")
    new, n = re.subn(pattern, repl, text, count=1, flags=flags)
    if n != 1:
        sys.exit(f"patch_windows: не нашёл «{what}» в {path} — шаблон Flutter изменился")
    p.write_text(new, encoding="utf-8")


runner = "windows/runner"

# Исходник в сборку
patch(f"{runner}/CMakeLists.txt", r'("main\.cpp")', r'\1\n  "locman_win.cpp"', '"main.cpp" в add_executable')

# flutter_window.cpp: канал и сообщения окна
patch(f"{runner}/flutter_window.cpp", r'(#include "flutter_window\.h"\n)', r'\1#include "locman_win.h"\n', "include flutter_window.h")
patch(
    f"{runner}/flutter_window.cpp",
    r"(RegisterPlugins\(flutter_controller_->engine\(\)\);)",
    r"\1\n  LocmanWin::Attach(flutter_controller_->engine()->messenger(), GetHandle());",
    "RegisterPlugins",
)
patch(
    f"{runner}/flutter_window.cpp",
    r"this->Show\(\);",
    "if (!LocmanWin::StartHidden()) this->Show();",
    "this->Show()",
)
patch(
    f"{runner}/flutter_window.cpp",
    r"(FlutterWindow::MessageHandler\(HWND hwnd,[^{]*\{\n)",
    r"\1  if (const auto own = LocmanWin::HandleMessage(hwnd, message, wparam, lparam)) {\n    return *own;\n  }\n",
    "FlutterWindow::MessageHandler",
    flags=re.S,
)

# main.cpp: один экземпляр, задание для процессов ядра, заголовок и размер окна
patch(f"{runner}/main.cpp", r'(#include "flutter_window\.h"\n)', r'\1#include "locman_win.h"\n', "include flutter_window.h")
patch(
    f"{runner}/main.cpp",
    r"(int APIENTRY wWinMain\([^{]*\{\n)",
    r"\1  if (LocmanWin::ForwardToRunningInstance()) {\n    return EXIT_SUCCESS;\n  }\n  LocmanWin::SetupJob();\n",
    "wWinMain",
    flags=re.S,
)
patch(f"{runner}/main.cpp", r"Win32Window::Size size\(\d+, \d+\);", "Win32Window::Size size(440, 880);", "Win32Window::Size")
patch(f"{runner}/main.cpp", r'window\.Create\(L"locman"', r'window.Create(L"\\u041b\\u043e\\u0446\\u043c\\u0430\\u043d"', 'window.Create(L"locman"')

print("patch_windows: готово")
for f in ("main.cpp", "flutter_window.cpp"):
    print(f"--- {f}")
    print(pathlib.Path(f"{runner}/{f}").read_text(encoding="utf-8"))
