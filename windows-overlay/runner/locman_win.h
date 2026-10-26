// «Лоцман» для Windows: то, что на Android делает Kotlin, — значок у часов, системный прокси,
// процессы ядра Xray, права администратора, автозапуск, один экземпляр и ссылки locman://.
#pragma once

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <optional>

namespace LocmanWin {

// true — «Лоцман» уже запущен: ему переданы аргументы (ссылка), этот процесс завершается.
bool ForwardToRunningInstance();

// Задание Windows: процессы ядра умирают вместе с приложением.
void SetupJob();

// Запуск с --autostart: окно не показываем, только значок у часов.
bool StartHidden();

// Канал locman/win и значок у часов.
void Attach(flutter::BinaryMessenger* messenger, HWND hwnd);

// Сообщения окна: значок, закрытие в трей, WM_COPYDATA, завершение сеанса.
std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

}  // namespace LocmanWin
