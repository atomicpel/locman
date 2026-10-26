// «Лоцман» для Windows — нативная часть (см. locman_win.h).
// Русские строки — через \u, чтобы не зависеть от кодировки исходников у компилятора.

#include "locman_win.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <wininet.h>
#include <bcrypt.h>

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "resource.h"

#pragma comment(lib, "wininet.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "advapi32.lib")

namespace LocmanWin {
namespace {

constexpr UINT kTrayMessage = WM_APP + 41;
constexpr UINT kTrayId = 1;
constexpr ULONG_PTR kCopyLink = 0x4C4D;
constexpr wchar_t kMutexName[] = L"Local\\LocmanSingleInstance";
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kTitle[] = L"Лоцман";  // Лоцман
constexpr wchar_t kInternetSettings[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kOwnKey[] = L"Software\\Locman";

HANDLE g_job = nullptr;
HANDLE g_mutex = nullptr;
HWND g_hwnd = nullptr;
bool g_close_to_tray = true;
bool g_tray_added = false;
bool g_connected = false;
bool g_quitting = false;
UINT g_taskbar_created = 0;
std::wstring g_tip = kTitle;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
std::map<int, HANDLE> g_procs;

std::wstring Widen(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

std::string Narrow(const std::wstring& w) {
  if (w.empty()) return std::string();
  const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
  std::string s(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
  return s;
}

std::vector<std::wstring> CommandArgs() {
  std::vector<std::wstring> out;
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr) return out;
  for (int i = 1; i < argc; i++) out.emplace_back(argv[i]);
  LocalFree(argv);
  return out;
}

std::wstring ExePath() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD n = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (n < path.size()) {
      path.resize(n);
      return path;
    }
    path.resize(path.size() * 2);
  }
}

// ---------- аргументы канала ----------

const flutter::EncodableValue* Find(const flutter::EncodableMap& m, const char* key) {
  const auto it = m.find(flutter::EncodableValue(std::string(key)));
  return it == m.end() ? nullptr : &it->second;
}

std::string Str(const flutter::EncodableMap& m, const char* key) {
  const auto* v = Find(m, key);
  if (v != nullptr) {
    if (const auto* s = std::get_if<std::string>(v)) return *s;
  }
  return std::string();
}

bool Bool(const flutter::EncodableMap& m, const char* key, bool fallback) {
  const auto* v = Find(m, key);
  if (v != nullptr) {
    if (const auto* b = std::get_if<bool>(v)) return *b;
  }
  return fallback;
}

int64_t Int(const flutter::EncodableMap& m, const char* key) {
  const auto* v = Find(m, key);
  if (v != nullptr) {
    if (const auto* i = std::get_if<int32_t>(v)) return *i;
    if (const auto* l = std::get_if<int64_t>(v)) return *l;
  }
  return 0;
}

void Invoke(const char* method, flutter::EncodableMap args) {
  if (g_channel) {
    g_channel->InvokeMethod(method, std::make_unique<flutter::EncodableValue>(std::move(args)));
  }
}

// ---------- значок у часов ----------

void TrayUpdate() {
  if (g_hwnd == nullptr) return;
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = g_hwnd;
  nid.uID = kTrayId;
  nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid.uCallbackMessage = kTrayMessage;
  nid.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcsncpy_s(nid.szTip, g_tip.c_str(), _TRUNCATE);
  if (!Shell_NotifyIconW(g_tray_added ? NIM_MODIFY : NIM_ADD, &nid) && g_tray_added) {
    Shell_NotifyIconW(NIM_ADD, &nid);
  }
  g_tray_added = true;
}

void TrayRemove() {
  if (!g_tray_added || g_hwnd == nullptr) return;
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = g_hwnd;
  nid.uID = kTrayId;
  Shell_NotifyIconW(NIM_DELETE, &nid);
  g_tray_added = false;
}

void ShowMain() {
  if (g_hwnd == nullptr) return;
  ShowWindow(g_hwnd, IsIconic(g_hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(g_hwnd);
}

void TrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  AppendMenuW(menu, MF_STRING, 1, L"Открыть");  // Открыть
  AppendMenuW(menu, MF_STRING, 2,
              g_connected ? L"Отключить"            // Отключить
                          : L"Подключить");  // Подключить
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 3, L"Выход");  // Выход
  POINT pt{};
  GetCursorPos(&pt);
  SetForegroundWindow(g_hwnd);
  const int cmd = static_cast<int>(
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, pt.x, pt.y, 0, g_hwnd, nullptr));
  DestroyMenu(menu);
  PostMessageW(g_hwnd, WM_NULL, 0, 0);
  switch (cmd) {
    case 1:
      ShowMain();
      break;
    case 2:
      Invoke("tray", {{flutter::EncodableValue("action"), flutter::EncodableValue("toggle")}});
      break;
    case 3:
      ShowMain();
      Invoke("tray", {{flutter::EncodableValue("action"), flutter::EncodableValue("exit")}});
      break;
    default:
      break;
  }
}

// ---------- системный прокси ----------

void RefreshInternetSettings() {
  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}

std::wstring ReadString(HKEY root, const wchar_t* path, const wchar_t* name) {
  wchar_t buf[1024] = {};
  DWORD size = sizeof(buf);
  if (RegGetValueW(root, path, name, RRF_RT_REG_SZ, nullptr, buf, &size) != ERROR_SUCCESS) return std::wstring();
  return std::wstring(buf);
}

DWORD ReadDword(HKEY root, const wchar_t* path, const wchar_t* name) {
  DWORD value = 0;
  DWORD size = sizeof(value);
  if (RegGetValueW(root, path, name, RRF_RT_REG_DWORD, nullptr, &value, &size) != ERROR_SUCCESS) return 0;
  return value;
}

void WriteString(HKEY root, const wchar_t* path, const wchar_t* name, const std::wstring& value) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(root, path, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return;
  RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
                 static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
}

void DeleteValue(HKEY root, const wchar_t* path, const wchar_t* name) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(root, path, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) return;
  RegDeleteValueW(key, name);
  RegCloseKey(key);
}

bool SetProxy(bool enable, const std::wstring& server, const std::wstring& bypass) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettings, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) return false;
  const DWORD on = enable ? 1 : 0;
  RegSetValueExW(key, L"ProxyEnable", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&on), sizeof(on));
  if (enable) {
    RegSetValueExW(key, L"ProxyServer", 0, REG_SZ, reinterpret_cast<const BYTE*>(server.c_str()),
                   static_cast<DWORD>((server.size() + 1) * sizeof(wchar_t)));
    RegSetValueExW(key, L"ProxyOverride", 0, REG_SZ, reinterpret_cast<const BYTE*>(bypass.c_str()),
                   static_cast<DWORD>((bypass.size() + 1) * sizeof(wchar_t)));
  }
  RegCloseKey(key);
  // Помним, что прокси наш: после сбоя снимем его при следующем запуске.
  if (enable) {
    WriteString(HKEY_CURRENT_USER, kOwnKey, L"ProxyServer", server);
  } else {
    DeleteValue(HKEY_CURRENT_USER, kOwnKey, L"ProxyServer");
  }
  RefreshInternetSettings();
  return true;
}

// Снять системный прокси, если он остался от «Лоцмана» (сбой, выключение питания).
void ResetStaleProxy() {
  const std::wstring ours = ReadString(HKEY_CURRENT_USER, kOwnKey, L"ProxyServer");
  if (ours.empty()) return;
  const std::wstring current = ReadString(HKEY_CURRENT_USER, kInternetSettings, L"ProxyServer");
  if (ReadDword(HKEY_CURRENT_USER, kInternetSettings, L"ProxyEnable") != 0 && current == ours) {
    SetProxy(false, std::wstring(), std::wstring());
  } else {
    DeleteValue(HKEY_CURRENT_USER, kOwnKey, L"ProxyServer");
  }
}

// ---------- процессы ядра ----------

int StartProcess(const std::wstring& exe, const std::wstring& args, const std::wstring& cwd) {
  std::wstring cmd = L"\"" + exe + L"\" " + args;
  std::vector<wchar_t> buf(cmd.begin(), cmd.end());
  buf.push_back(L'\0');
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (!CreateProcessW(exe.c_str(), buf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr,
                      cwd.empty() ? nullptr : cwd.c_str(), &si, &pi)) {
    return -1;
  }
  if (g_job != nullptr) AssignProcessToJobObject(g_job, pi.hProcess);
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);
  const int pid = static_cast<int>(pi.dwProcessId);
  g_procs[pid] = pi.hProcess;
  return pid;
}

void KillProcess(int pid) {
  const auto it = g_procs.find(pid);
  if (it == g_procs.end()) return;
  TerminateProcess(it->second, 0);
  WaitForSingleObject(it->second, 3000);
  CloseHandle(it->second);
  g_procs.erase(it);
}

bool Alive(int pid) {
  const auto it = g_procs.find(pid);
  if (it == g_procs.end()) return false;
  return WaitForSingleObject(it->second, 0) == WAIT_TIMEOUT;
}

void KillAll() {
  for (auto& p : g_procs) {
    TerminateProcess(p.second, 0);
    CloseHandle(p.second);
  }
  g_procs.clear();
}

// ---------- права администратора ----------

bool IsElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION elevation{};
  DWORD size = 0;
  const bool ok = GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &size) != 0;
  CloseHandle(token);
  return ok && elevation.TokenIsElevated != 0;
}

bool RelaunchAdmin() {
  // Отпускаем «один экземпляр», иначе новый процесс отдаст аргументы нам и закроется.
  if (g_mutex != nullptr) {
    ReleaseMutex(g_mutex);
    CloseHandle(g_mutex);
    g_mutex = nullptr;
  }
  const std::wstring exe = ExePath();
  SHELLEXECUTEINFOW sei{};
  sei.cbSize = sizeof(sei);
  sei.fMask = SEE_MASK_NOASYNC;
  sei.lpVerb = L"runas";
  sei.lpFile = exe.c_str();
  sei.lpParameters = L"--elevated";
  sei.nShow = SW_SHOWNORMAL;
  if (ShellExecuteExW(&sei)) return true;
  g_mutex = CreateMutexW(nullptr, TRUE, kMutexName);
  return false;
}

// ---------- автозапуск ----------

bool RunHidden(const std::wstring& exe, const std::wstring& args) {
  std::wstring cmd = L"\"" + exe + L"\" " + args;
  std::vector<wchar_t> buf(cmd.begin(), cmd.end());
  buf.push_back(L'\0');
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (!CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
    return false;
  }
  WaitForSingleObject(pi.hProcess, 15000);
  DWORD code = 1;
  GetExitCodeProcess(pi.hProcess, &code);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return code == 0;
}

std::wstring SystemExe(const wchar_t* name) {
  wchar_t dir[MAX_PATH] = {};
  GetSystemDirectoryW(dir, MAX_PATH);
  return std::wstring(dir) + L"\\" + name;
}

std::wstring XmlEscape(const std::wstring& s) {
  std::wstring out;
  for (const wchar_t c : s) {
    switch (c) {
      case L'&':
        out += L"&amp;";
        break;
      case L'<':
        out += L"&lt;";
        break;
      case L'>':
        out += L"&gt;";
        break;
      default:
        out += c;
    }
  }
  return out;
}

// Задание планировщика «при входе в систему» с наивысшими правами — для TUN.
bool CreateElevatedTask(const std::wstring& exe) {
  wchar_t user[256] = {};
  wchar_t domain[256] = {};
  GetEnvironmentVariableW(L"USERNAME", user, 256);
  GetEnvironmentVariableW(L"USERDOMAIN", domain, 256);
  const std::wstring account = std::wstring(domain) + L"\\" + user;
  const std::wstring xml =
      L"<?xml version=\"1.0\" encoding=\"UTF-16\"?>\r\n"
      L"<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\r\n"
      L"<Triggers><LogonTrigger><Enabled>true</Enabled><UserId>" + XmlEscape(account) + L"</UserId></LogonTrigger></Triggers>\r\n"
      L"<Principals><Principal id=\"Author\"><UserId>" + XmlEscape(account) +
      L"</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>\r\n"
      L"<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>"
      L"<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>"
      L"<ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Enabled>true</Enabled></Settings>\r\n"
      L"<Actions Context=\"Author\"><Exec><Command>" + XmlEscape(exe) +
      L"</Command><Arguments>--autostart</Arguments></Exec></Actions>\r\n"
      L"</Task>\r\n";
  wchar_t tmp[MAX_PATH] = {};
  GetTempPathW(MAX_PATH, tmp);
  const std::wstring file = std::wstring(tmp) + L"locman-task.xml";
  HANDLE h = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return false;
  const wchar_t bom = 0xFEFF;
  DWORD written = 0;
  WriteFile(h, &bom, sizeof(bom), &written, nullptr);
  WriteFile(h, xml.c_str(), static_cast<DWORD>(xml.size() * sizeof(wchar_t)), &written, nullptr);
  CloseHandle(h);
  const bool ok = RunHidden(SystemExe(L"schtasks.exe"), L"/Create /TN \"Locman\" /XML \"" + file + L"\" /F");
  DeleteFileW(file.c_str());
  return ok;
}

void SetAutostart(bool enable, bool elevated) {
  const std::wstring exe = ExePath();
  if (!enable) {
    DeleteValue(HKEY_CURRENT_USER, kRunKey, L"Locman");
    if (IsElevated()) RunHidden(SystemExe(L"schtasks.exe"), L"/Delete /TN \"Locman\" /F");
    return;
  }
  if (elevated && IsElevated() && CreateElevatedTask(exe)) {
    DeleteValue(HKEY_CURRENT_USER, kRunKey, L"Locman");
    return;
  }
  WriteString(HKEY_CURRENT_USER, kRunKey, L"Locman", L"\"" + exe + L"\" --autostart");
}

// ---------- прочее ----------

std::string Sha256File(const std::wstring& path) {
  BCRYPT_ALG_HANDLE alg = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  std::string hex;
  if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0))) return hex;
  if (BCRYPT_SUCCESS(BCryptCreateHash(alg, &hash, nullptr, 0, nullptr, 0, 0))) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f != INVALID_HANDLE_VALUE) {
      std::vector<UCHAR> buf(1 << 16);
      DWORD read = 0;
      bool ok = true;
      while (ReadFile(f, buf.data(), static_cast<DWORD>(buf.size()), &read, nullptr) && read > 0) {
        if (!BCRYPT_SUCCESS(BCryptHashData(hash, buf.data(), read, 0))) {
          ok = false;
          break;
        }
      }
      CloseHandle(f);
      UCHAR digest[32] = {};
      if (ok && BCRYPT_SUCCESS(BCryptFinishHash(hash, digest, sizeof(digest), 0))) {
        static const char kHex[] = "0123456789abcdef";
        for (const UCHAR b : digest) {
          hex += kHex[b >> 4];
          hex += kHex[b & 0x0F];
        }
      }
    }
    BCryptDestroyHash(hash);
  }
  BCryptCloseAlgorithmProvider(alg, 0);
  return hex;
}

bool OpenUrl(const std::wstring& url) {
  if (url.rfind(L"https://", 0) != 0 && url.rfind(L"http://", 0) != 0) return false;
  return reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) > 32;
}

bool RunFile(const std::wstring& path, const std::wstring& args) {
  return reinterpret_cast<INT_PTR>(
             ShellExecuteW(nullptr, L"open", path.c_str(), args.empty() ? nullptr : args.c_str(), nullptr, SW_SHOWNORMAL)) > 32;
}

void Cleanup() {
  const std::wstring ours = ReadString(HKEY_CURRENT_USER, kOwnKey, L"ProxyServer");
  if (!ours.empty()) SetProxy(false, std::wstring(), std::wstring());
  KillAll();
  TrayRemove();
}

void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& name = call.method_name();
  static const flutter::EncodableMap kEmpty;
  const auto* map = call.arguments() == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableMap& a = map != nullptr ? *map : kEmpty;

  if (name == "startProcess") {
    const int pid = StartProcess(Widen(Str(a, "exe")), Widen(Str(a, "args")), Widen(Str(a, "cwd")));
    if (pid < 0) {
      result->Success();
    } else {
      result->Success(flutter::EncodableValue(pid));
    }
  } else if (name == "killProcess") {
    KillProcess(static_cast<int>(Int(a, "pid")));
    result->Success();
  } else if (name == "alive") {
    result->Success(flutter::EncodableValue(Alive(static_cast<int>(Int(a, "pid")))));
  } else if (name == "setProxy") {
    result->Success(flutter::EncodableValue(
        SetProxy(Bool(a, "enable", false), Widen(Str(a, "server")), Widen(Str(a, "bypass")))));
  } else if (name == "resetStaleProxy") {
    ResetStaleProxy();
    result->Success();
  } else if (name == "isAdmin") {
    result->Success(flutter::EncodableValue(IsElevated()));
  } else if (name == "relaunchAdmin") {
    result->Success(flutter::EncodableValue(RelaunchAdmin()));
  } else if (name == "quit") {
    g_quitting = true;
    result->Success();
    PostMessageW(g_hwnd, WM_CLOSE, 0, 0);
  } else if (name == "showWindow") {
    ShowMain();
    result->Success();
  } else if (name == "setCloseToTray") {
    g_close_to_tray = Bool(a, "on", true);
    result->Success();
  } else if (name == "tray") {
    g_connected = Bool(a, "connected", false);
    const std::string tip = Str(a, "tooltip");
    if (!tip.empty()) g_tip = Widen(tip);
    TrayUpdate();
    result->Success();
  } else if (name == "openUrl") {
    result->Success(flutter::EncodableValue(OpenUrl(Widen(Str(a, "url")))));
  } else if (name == "runFile") {
    result->Success(flutter::EncodableValue(RunFile(Widen(Str(a, "path")), Widen(Str(a, "args")))));
  } else if (name == "sha256") {
    const std::string hex = Sha256File(Widen(Str(a, "path")));
    if (hex.empty()) {
      result->Success();
    } else {
      result->Success(flutter::EncodableValue(hex));
    }
  } else if (name == "setAutostart") {
    SetAutostart(Bool(a, "enable", false), Bool(a, "elevated", false));
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace

bool ForwardToRunningInstance() {
  g_mutex = CreateMutexW(nullptr, TRUE, kMutexName);
  if (GetLastError() != ERROR_ALREADY_EXISTS) return false;
  HWND other = FindWindowW(kWindowClass, kTitle);
  if (other == nullptr) return false;
  std::string link;
  for (const auto& arg : CommandArgs()) {
    if (_wcsnicmp(arg.c_str(), L"locman:", 7) == 0) link = Narrow(arg);
  }
  COPYDATASTRUCT cds{};
  cds.dwData = kCopyLink;
  cds.cbData = static_cast<DWORD>(link.size());
  cds.lpData = link.empty() ? nullptr : link.data();
  DWORD_PTR ignored = 0;
  SendMessageTimeoutW(other, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds), SMTO_ABORTIFHUNG, 3000, &ignored);
  return true;
}

void SetupJob() {
  g_job = CreateJobObjectW(nullptr, nullptr);
  if (g_job == nullptr) return;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
  info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  SetInformationJobObject(g_job, JobObjectExtendedLimitInformation, &info, sizeof(info));
}

bool StartHidden() {
  for (const auto& arg : CommandArgs()) {
    if (arg == L"--autostart") return true;
  }
  return false;
}

void Attach(flutter::BinaryMessenger* messenger, HWND hwnd) {
  g_hwnd = hwnd;
  g_taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  // Ссылки от второго экземпляра доходят и до окна с правами администратора.
  ChangeWindowMessageFilterEx(hwnd, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "locman/win", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleCall);
  TrayUpdate();
}

std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kTrayMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        ShowMain();
        break;
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        TrayMenu();
        break;
      default:
        break;
    }
    return 0;
  }
  if (g_taskbar_created != 0 && message == g_taskbar_created) {
    g_tray_added = false;
    TrayUpdate();
    return std::nullopt;
  }
  switch (message) {
    case WM_CLOSE:
      if (g_close_to_tray && !g_quitting) {
        ShowWindow(hwnd, SW_HIDE);
        TrayUpdate();
        return 0;
      }
      break;
    case WM_COPYDATA: {
      const auto* cds = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (cds == nullptr || cds->dwData != kCopyLink) break;
      ShowMain();
      if (cds->cbData > 0 && cds->cbData < 65536 && cds->lpData != nullptr) {
        const std::string link(static_cast<const char*>(cds->lpData), cds->cbData);
        Invoke("link", {{flutter::EncodableValue("url"), flutter::EncodableValue(link)}});
      }
      return TRUE;
    }
    case WM_ENDSESSION:
      if (wparam != 0) Cleanup();
      return 0;
    case WM_DESTROY:
      Cleanup();
      break;
    default:
      break;
  }
  return std::nullopt;
}

}  // namespace LocmanWin
