#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <windowsx.h>
#include <GL/gl.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include <node_api.h>

#include "ghostty.h"

namespace {

constexpr wchar_t kTerminalWindowClass[] =
    L"GhosttyElectronNativeTerminalWindow";
constexpr UINT kWakeupMessage = WM_APP + 0x317;
constexpr UINT kCopyCommand = 1;
constexpr UINT kPasteCommand = 2;

constexpr int kWglContextMajorVersionArb = 0x2091;
constexpr int kWglContextMinorVersionArb = 0x2092;
constexpr int kWglContextProfileMaskArb = 0x9126;
constexpr int kWglContextCoreProfileBitArb = 0x00000001;
constexpr int kWglContextCompatibilityProfileBitArb = 0x00000002;

using WglCreateContextAttribsArb = HGLRC(WINAPI*)(HDC, HGLRC, const int*);
using WglChoosePixelFormatFn = int(WINAPI*)(HDC, const PIXELFORMATDESCRIPTOR*);
using WglCreateContextFn = HGLRC(WINAPI*)(HDC);
using WglDeleteContextFn = BOOL(WINAPI*)(HGLRC);
using WglGetCurrentContextFn = HGLRC(WINAPI*)();
using WglGetProcAddressFn = PROC(WINAPI*)(LPCSTR);
using WglMakeCurrentFn = BOOL(WINAPI*)(HDC, HGLRC);
using WglSetPixelFormatFn = BOOL(WINAPI*)(HDC,
                                         int,
                                         const PIXELFORMATDESCRIPTOR*);
using WglSwapBuffersFn = BOOL(WINAPI*)(HDC);
using GlGetStringFn = const GLubyte*(APIENTRY*)(GLenum);

void Trace(const char* message) {
  char trace_path[MAX_PATH] = {};
  if (GetEnvironmentVariableA("GHOSTTY_EMBED_TRACE", trace_path,
                              std::size(trace_path)) != 0) {
    HANDLE trace = CreateFileA(trace_path, FILE_APPEND_DATA,
                               FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                               OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (trace != INVALID_HANDLE_VALUE) {
      const char prefix[] = "[ghostty-embed] ";
      const char newline[] = "\r\n";
      DWORD written = 0;
      WriteFile(trace, prefix, sizeof(prefix) - 1, &written, nullptr);
      WriteFile(trace, message, static_cast<DWORD>(std::strlen(message)),
                &written, nullptr);
      WriteFile(trace, newline, sizeof(newline) - 1, &written, nullptr);
      CloseHandle(trace);
    }
  }
}

struct GhosttyHost {
  ghostty_config_t config = nullptr;
  ghostty_app_t app = nullptr;
  ghostty_surface_t surface = nullptr;
  HWND parent = nullptr;
  HWND child = nullptr;
  HDC device_context = nullptr;
  HGLRC render_context = nullptr;
  HMODULE opengl_module = nullptr;
  WglChoosePixelFormatFn wgl_choose_pixel_format = nullptr;
  WglCreateContextFn wgl_create_context = nullptr;
  WglDeleteContextFn wgl_delete_context = nullptr;
  WglGetCurrentContextFn wgl_get_current_context = nullptr;
  WglGetProcAddressFn wgl_get_proc_address = nullptr;
  WglMakeCurrentFn wgl_make_current = nullptr;
  WglSetPixelFormatFn wgl_set_pixel_format = nullptr;
  WglSwapBuffersFn wgl_swap_buffers = nullptr;
  GlGetStringFn gl_get_string = nullptr;
  CRITICAL_SECTION context_lock = {};
  bool context_lock_initialized = false;
  std::atomic<bool> closing = false;
  std::atomic<bool> renderer_healthy = true;
  std::atomic<uint64_t> swaps = 0;
  bool left_captured = false;
  bool right_captured = false;
  wchar_t pending_high_surrogate = 0;
  int modifier_latch = GHOSTTY_MODS_NONE;
  std::string gl_version;
  std::string pixel_format_api;
};

void Throw(napi_env env, const char* message) {
  napi_throw_error(env, "ERR_GHOSTTY_EMBED", message);
}

bool GetNamedDouble(napi_env env,
                    napi_value object,
                    const char* name,
                    double* result) {
  napi_value value;
  if (napi_get_named_property(env, object, name, &value) != napi_ok)
    return false;
  return napi_get_value_double(env, value, result) == napi_ok;
}

std::string GetNamedString(napi_env env, napi_value object, const char* name) {
  napi_value value;
  if (napi_get_named_property(env, object, name, &value) != napi_ok)
    return {};

  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok)
    return {};

  std::string result(length + 1, '\0');
  if (napi_get_value_string_utf8(env, value, result.data(), result.size(),
                                 &length) != napi_ok) {
    return {};
  }
  result.resize(length);
  return result;
}

std::string WideToUtf8(const wchar_t* value, int length = -1) {
  if (!value)
    return {};
  const int output_length =
      WideCharToMultiByte(CP_UTF8, 0, value, length, nullptr, 0, nullptr,
                          nullptr);
  if (output_length <= 0)
    return {};
  std::string result(output_length, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, length, result.data(), output_length,
                      nullptr, nullptr);
  if (length == -1 && !result.empty() && result.back() == '\0')
    result.pop_back();
  return result;
}

std::wstring Utf8ToWide(const char* value) {
  if (!value)
    return {};
  const int output_length =
      MultiByteToWideChar(CP_UTF8, 0, value, -1, nullptr, 0);
  if (output_length <= 0)
    return {};
  std::wstring result(output_length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value, -1, result.data(), output_length);
  return result;
}

ghostty_input_mods_e CurrentModifiers(const GhosttyHost* host) {
  int mods = host ? host->modifier_latch : GHOSTTY_MODS_NONE;
  if (GetKeyState(VK_CAPITAL) & 1)
    mods |= GHOSTTY_MODS_CAPS;
  if (GetKeyState(VK_NUMLOCK) & 1)
    mods |= GHOSTTY_MODS_NUM;
  return static_cast<ghostty_input_mods_e>(mods);
}

void UpdateModifierLatch(GhosttyHost* host,
                         WPARAM virtual_key,
                         LPARAM lparam,
                         bool down) {
  if (!host)
    return;
  int bits = 0;
  switch (virtual_key) {
    case VK_SHIFT:
    case VK_LSHIFT:
    case VK_RSHIFT: {
      bits = GHOSTTY_MODS_SHIFT;
      const UINT scan_code = static_cast<UINT>((lparam >> 16) & 0xff);
      const UINT resolved = virtual_key == VK_SHIFT
                                ? MapVirtualKeyW(scan_code, MAPVK_VSC_TO_VK_EX)
                                : static_cast<UINT>(virtual_key);
      if (resolved == VK_RSHIFT)
        bits |= GHOSTTY_MODS_SHIFT_RIGHT;
      break;
    }
    case VK_CONTROL:
    case VK_LCONTROL:
    case VK_RCONTROL:
      bits = GHOSTTY_MODS_CTRL;
      if (virtual_key == VK_RCONTROL || (lparam & (1LL << 24)))
        bits |= GHOSTTY_MODS_CTRL_RIGHT;
      break;
    case VK_MENU:
    case VK_LMENU:
    case VK_RMENU:
      bits = GHOSTTY_MODS_ALT;
      if (virtual_key == VK_RMENU || (lparam & (1LL << 24)))
        bits |= GHOSTTY_MODS_ALT_RIGHT;
      break;
    case VK_LWIN:
    case VK_RWIN:
      bits = GHOSTTY_MODS_SUPER;
      if (virtual_key == VK_RWIN)
        bits |= GHOSTTY_MODS_SUPER_RIGHT;
      break;
    default:
      return;
  }
  if (down)
    host->modifier_latch |= bits;
  else
    host->modifier_latch &= ~bits;
}

uint32_t NativeScanCode(LPARAM lparam) {
  uint32_t scan_code = static_cast<uint32_t>((lparam >> 16) & 0xff);
  if ((lparam & (1LL << 24)) != 0)
    scan_code |= 0xe000;
  return scan_code;
}

uint32_t UnshiftedCodepoint(WPARAM virtual_key) {
  if (virtual_key >= 'A' && virtual_key <= 'Z')
    return static_cast<uint32_t>('a' + (virtual_key - 'A'));
  if (virtual_key >= '0' && virtual_key <= '9')
    return static_cast<uint32_t>(virtual_key);
  return 0;
}

bool IsTextProducingKey(WPARAM virtual_key) {
  return virtual_key == VK_SPACE ||
         (virtual_key >= '0' && virtual_key <= '9') ||
         (virtual_key >= 'A' && virtual_key <= 'Z') ||
         (virtual_key >= VK_NUMPAD0 && virtual_key <= VK_DIVIDE) ||
         (virtual_key >= VK_OEM_1 && virtual_key <= VK_OEM_8) ||
         virtual_key == VK_OEM_102;
}

bool HasCommandModifier(const GhosttyHost* host) {
  return host &&
         (host->modifier_latch &
          (GHOSTTY_MODS_CTRL | GHOSTTY_MODS_ALT | GHOSTTY_MODS_SUPER));
}

int DipToPixel(HWND window, double value) {
  const UINT dpi = window ? GetDpiForWindow(window) : 96;
  const double scale = dpi > 0 ? static_cast<double>(dpi) / 96.0 : 1.0;
  return static_cast<int>(std::lround(value * scale));
}

void SendMousePosition(GhosttyHost* host, LPARAM lparam) {
  if (!host || !host->surface)
    return;
  ghostty_surface_mouse_pos(host->surface, GET_X_LPARAM(lparam),
                            GET_Y_LPARAM(lparam), CurrentModifiers(host));
}

void UpdateSurfaceMetrics(GhosttyHost* host) {
  if (!host || !host->surface || !host->child)
    return;
  RECT bounds = {};
  if (!GetClientRect(host->child, &bounds))
    return;
  const UINT dpi = GetDpiForWindow(host->child);
  const double scale = dpi > 0 ? static_cast<double>(dpi) / 96.0 : 1.0;
  ghostty_surface_set_content_scale(host->surface, scale, scale);
  ghostty_surface_set_size(
      host->surface, static_cast<uint32_t>(bounds.right - bounds.left),
      static_cast<uint32_t>(bounds.bottom - bounds.top));
}

void* WglGetProcAddress(void* userdata, const char* name) {
  auto* host = static_cast<GhosttyHost*>(userdata);
  if (!host || !name || !host->wgl_get_proc_address)
    return nullptr;
  PROC proc = host->wgl_get_proc_address(name);
  if (proc && proc != reinterpret_cast<PROC>(1) &&
      proc != reinterpret_cast<PROC>(2) &&
      proc != reinterpret_cast<PROC>(3) &&
      proc != reinterpret_cast<PROC>(-1)) {
    return reinterpret_cast<void*>(proc);
  }
  return host->opengl_module
             ? reinterpret_cast<void*>(GetProcAddress(host->opengl_module, name))
             : nullptr;
}

bool WglMakeCurrent(void* userdata) {
  auto* host = static_cast<GhosttyHost*>(userdata);
  if (!host || !host->device_context || !host->render_context)
    return false;
  EnterCriticalSection(&host->context_lock);
  if (!host->wgl_make_current(host->device_context, host->render_context)) {
    LeaveCriticalSection(&host->context_lock);
    return false;
  }
  return true;
}

void WglClearCurrent(void* userdata) {
  auto* host = static_cast<GhosttyHost*>(userdata);
  if (!host)
    return;
  host->wgl_make_current(nullptr, nullptr);
  LeaveCriticalSection(&host->context_lock);
}

void WglSwapBuffers(void* userdata) {
  auto* host = static_cast<GhosttyHost*>(userdata);
  if (!host || !host->device_context)
    return;
  if (host->wgl_swap_buffers(host->device_context))
    host->swaps.fetch_add(1, std::memory_order_relaxed);
  else
    host->renderer_healthy.store(false, std::memory_order_release);
}

bool VersionAtLeast43(const char* version) {
  if (!version)
    return false;
  int major = 0;
  int minor = 0;
  if (sscanf_s(version, "%d.%d", &major, &minor) != 2)
    return false;
  return major > 4 || (major == 4 && minor >= 3);
}

bool LoadWglApi(GhosttyHost* host, std::string* error) {
  wchar_t override_path[MAX_PATH] = {};
  const DWORD override_length = GetEnvironmentVariableW(
      L"GHOSTTY_MESA_OPENGL_PATH", override_path, std::size(override_path));
  const bool has_opengl_override =
      override_length > 0 && override_length < std::size(override_path);
  if (has_opengl_override) {
    host->opengl_module = LoadLibraryExW(
        override_path, nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  } else {
    host->opengl_module = LoadLibraryW(L"opengl32.dll");
  }
  if (!host->opengl_module) {
    *error = "Unable to load the requested OpenGL implementation";
    return false;
  }

  const auto load = [host](const char* name) {
    return GetProcAddress(host->opengl_module, name);
  };
  host->wgl_create_context =
      reinterpret_cast<WglCreateContextFn>(load("wglCreateContext"));
  host->wgl_delete_context =
      reinterpret_cast<WglDeleteContextFn>(load("wglDeleteContext"));
  host->wgl_get_current_context = reinterpret_cast<WglGetCurrentContextFn>(
      load("wglGetCurrentContext"));
  host->wgl_get_proc_address =
      reinterpret_cast<WglGetProcAddressFn>(load("wglGetProcAddress"));
  host->wgl_make_current =
      reinterpret_cast<WglMakeCurrentFn>(load("wglMakeCurrent"));
  host->gl_get_string =
      reinterpret_cast<GlGetStringFn>(load("glGetString"));

  // Mesa's drop-in OpenGL DLL owns its pixel-format and swap entrypoints.
  // The Windows system OpenGL path instead requires the public GDI APIs.
  // opengl32.dll exports similarly named WGL helpers, but its
  // wglSetPixelFormat can report success without setting the HDC format.
  if (has_opengl_override) {
    host->wgl_choose_pixel_format = reinterpret_cast<WglChoosePixelFormatFn>(
        load("wglChoosePixelFormat"));
    host->wgl_set_pixel_format = reinterpret_cast<WglSetPixelFormatFn>(
        load("wglSetPixelFormat"));
    host->wgl_swap_buffers =
        reinterpret_cast<WglSwapBuffersFn>(load("wglSwapBuffers"));
    host->pixel_format_api = "OpenGL override DLL";
  } else {
    host->wgl_choose_pixel_format = &::ChoosePixelFormat;
    host->wgl_set_pixel_format = &::SetPixelFormat;
    host->wgl_swap_buffers = &::SwapBuffers;
    host->pixel_format_api = "GDI32";
  }
  if (!host->wgl_choose_pixel_format || !host->wgl_create_context ||
      !host->wgl_delete_context ||
      !host->wgl_get_current_context || !host->wgl_get_proc_address ||
      !host->wgl_make_current || !host->wgl_set_pixel_format ||
      !host->wgl_swap_buffers || !host->gl_get_string) {
    *error = "The requested OpenGL DLL is missing required WGL exports";
    return false;
  }
  return true;
}

bool InitializeWgl(GhosttyHost* host, std::string* error) {
  if (!LoadWglApi(host, error))
    return false;
  host->device_context = GetDC(host->child);
  if (!host->device_context) {
    *error = "GetDC failed for the native terminal child HWND";
    return false;
  }

  PIXELFORMATDESCRIPTOR format = {};
  format.nSize = sizeof(format);
  format.nVersion = 1;
  format.dwFlags =
      PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
  format.iPixelType = PFD_TYPE_RGBA;
  format.cColorBits = 32;
  format.cAlphaBits = 8;
  format.cDepthBits = 24;
  format.cStencilBits = 8;
  format.iLayerType = PFD_MAIN_PLANE;

  const int pixel_format =
      host->wgl_choose_pixel_format(host->device_context, &format);
  if (pixel_format == 0 ||
      !host->wgl_set_pixel_format(host->device_context, pixel_format,
                                  &format)) {
    *error = "Unable to set a double-buffered WGL pixel format";
    return false;
  }

  HGLRC legacy = host->wgl_create_context(host->device_context);
  if (!legacy || !host->wgl_make_current(host->device_context, legacy)) {
    *error = "Unable to create the WGL bootstrap context";
    if (legacy)
      host->wgl_delete_context(legacy);
    return false;
  }

  auto create_context = reinterpret_cast<WglCreateContextAttribsArb>(
      host->wgl_get_proc_address("wglCreateContextAttribsARB"));
  HGLRC modern = nullptr;
  if (create_context) {
    const int profiles[] = {kWglContextCoreProfileBitArb,
                            kWglContextCompatibilityProfileBitArb};
    const int versions[][2] = {{4, 5}, {4, 3}};
    for (const auto& version : versions) {
      for (const int profile : profiles) {
        const int attributes[] = {
            kWglContextMajorVersionArb,
            version[0],
            kWglContextMinorVersionArb,
            version[1],
            kWglContextProfileMaskArb,
            profile,
            0,
        };
        modern = create_context(host->device_context, nullptr, attributes);
        if (modern)
          break;
      }
      if (modern)
        break;
    }
  }

  if (modern) {
    host->wgl_make_current(nullptr, nullptr);
    host->wgl_delete_context(legacy);
    host->render_context = modern;
    if (!host->wgl_make_current(host->device_context,
                                host->render_context)) {
      *error = "Unable to activate the OpenGL 4.3 WGL context";
      return false;
    }
  } else {
    host->render_context = legacy;
  }

  const char* version =
      reinterpret_cast<const char*>(host->gl_get_string(GL_VERSION));
  host->gl_version = version ? version : "unknown";
  if (!VersionAtLeast43(version)) {
    *error = "Ghostty requires OpenGL 4.3; WGL reported " + host->gl_version;
    host->wgl_make_current(nullptr, nullptr);
    return false;
  }
  host->wgl_make_current(nullptr, nullptr);
  return true;
}

void DestroyWgl(GhosttyHost* host) {
  if (!host)
    return;
  // Surface.deinit joins the renderer thread and then enters the renderer
  // once on the caller thread so GPU resources can be freed. Balance that
  // final make_current before taking the lock for context destruction.
  if (host->render_context && host->wgl_get_current_context &&
      host->wgl_get_current_context() == host->render_context) {
    host->wgl_make_current(nullptr, nullptr);
    LeaveCriticalSection(&host->context_lock);
  }
  if (host->context_lock_initialized)
    EnterCriticalSection(&host->context_lock);
  if (host->render_context) {
    host->wgl_delete_context(host->render_context);
    host->render_context = nullptr;
  }
  if (host->device_context && host->child) {
    ReleaseDC(host->child, host->device_context);
    host->device_context = nullptr;
  }
  if (host->context_lock_initialized) {
    LeaveCriticalSection(&host->context_lock);
    DeleteCriticalSection(&host->context_lock);
    host->context_lock_initialized = false;
  }
  if (host->opengl_module) {
    FreeLibrary(host->opengl_module);
    host->opengl_module = nullptr;
  }
}

bool ReadClipboard(void* userdata, ghostty_clipboard_e type, void* state) {
  Trace("clipboard: read requested");
  auto* host = static_cast<GhosttyHost*>(userdata);
  if (!host || !host->surface || type != GHOSTTY_CLIPBOARD_STANDARD)
    return false;
  if (!OpenClipboard(host->child))
    return false;
  HANDLE value_handle = GetClipboardData(CF_UNICODETEXT);
  const wchar_t* value = value_handle
                             ? static_cast<const wchar_t*>(GlobalLock(value_handle))
                             : nullptr;
  const std::string utf8 = value ? WideToUtf8(value) : std::string();
  if (value)
    GlobalUnlock(value_handle);
  CloseClipboard();
  if (utf8.empty())
    return false;
  Trace("clipboard: read completed");
  ghostty_surface_complete_clipboard_request(host->surface, utf8.c_str(), state,
                                             false);
  return true;
}

void ConfirmReadClipboard(void* userdata,
                          const char* value,
                          void* state,
                          ghostty_clipboard_request_e) {
  Trace("clipboard: read confirmed");
  auto* host = static_cast<GhosttyHost*>(userdata);
  if (host && host->surface)
    ghostty_surface_complete_clipboard_request(host->surface, value, state,
                                               true);
}

void WriteClipboard(void* userdata,
                    ghostty_clipboard_e type,
                    const ghostty_clipboard_content_s* content,
                    size_t length,
                    bool) {
  Trace("clipboard: write requested");
  auto* host = static_cast<GhosttyHost*>(userdata);
  if (!host || type != GHOSTTY_CLIPBOARD_STANDARD || !content)
    return;
  for (size_t index = 0; index < length; ++index) {
    if (!content[index].mime || !content[index].data ||
        std::strcmp(content[index].mime, "text/plain") != 0) {
      continue;
    }
    const std::wstring wide = Utf8ToWide(content[index].data);
    if (wide.empty() || !OpenClipboard(host->child))
      return;
    EmptyClipboard();
    const SIZE_T bytes = wide.size() * sizeof(wchar_t);
    HGLOBAL allocation = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (allocation) {
      void* destination = GlobalLock(allocation);
      if (destination) {
        std::memcpy(destination, wide.data(), bytes);
        GlobalUnlock(allocation);
        if (!SetClipboardData(CF_UNICODETEXT, allocation))
          GlobalFree(allocation);
        else
          Trace("clipboard: write completed");
      } else {
        GlobalFree(allocation);
      }
    }
    CloseClipboard();
    return;
  }
}

void Wakeup(void* userdata) {
  auto* host = static_cast<GhosttyHost*>(userdata);
  if (host && !host->closing.load(std::memory_order_acquire) && host->child)
    PostMessageW(host->child, kWakeupMessage, 0, 0);
}

bool Action(ghostty_app_t app,
            ghostty_target_s,
            ghostty_action_s action) {
  auto* host = static_cast<GhosttyHost*>(ghostty_app_userdata(app));
  if (!host)
    return false;
  if (host->closing.load(std::memory_order_acquire)) {
    return action.tag == GHOSTTY_ACTION_RENDER ||
           action.tag == GHOSTTY_ACTION_RENDERER_HEALTH;
  }
  switch (action.tag) {
    case GHOSTTY_ACTION_RENDER:
      if (host->surface)
        ghostty_surface_refresh(host->surface);
      return true;
    case GHOSTTY_ACTION_RENDERER_HEALTH:
      host->renderer_healthy.store(
          action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY,
          std::memory_order_release);
      return true;
    default:
      return false;
  }
}

void CloseSurface(void*, bool) {}

bool EnsureGhosttyInitialized() {
  static std::once_flag once;
  static int result = -1;
  std::call_once(once, [] {
    char process_name[] = "electron-libghostty-windows";
    char* argv[] = {process_name};
    result = ghostty_init(1, argv);
  });
  return result == GHOSTTY_SUCCESS;
}

void SendKey(GhosttyHost* host,
             ghostty_input_action_e action,
             WPARAM virtual_key,
             LPARAM lparam) {
  if (!host || !host->surface)
    return;
  ghostty_input_key_s key = {};
  key.action = action;
  key.mods = CurrentModifiers(host);
  key.consumed_mods = GHOSTTY_MODS_NONE;
  key.keycode = NativeScanCode(lparam);
  key.unshifted_codepoint = UnshiftedCodepoint(virtual_key);
  key.text = nullptr;
  ghostty_surface_key(host->surface, key);
}

void SendUtf16Character(GhosttyHost* host, wchar_t character) {
  if (!host || !host->surface)
    return;
  if (character >= 0xd800 && character <= 0xdbff) {
    host->pending_high_surrogate = character;
    return;
  }
  wchar_t utf16[3] = {};
  int length = 1;
  if (character >= 0xdc00 && character <= 0xdfff &&
      host->pending_high_surrogate) {
    utf16[0] = host->pending_high_surrogate;
    utf16[1] = character;
    length = 2;
  } else {
    utf16[0] = character;
  }
  host->pending_high_surrogate = 0;
  const std::string utf8 = WideToUtf8(utf16, length);
  if (!utf8.empty())
    ghostty_surface_text_input(host->surface, utf8.data(), utf8.size());
}

void InvokeBinding(GhosttyHost* host, const char* action) {
  if (!host || !host->surface || !action)
    return;
  if (ghostty_surface_binding_action(host->surface, action,
                                    std::strlen(action))) {
    Trace("binding: action handled");
  } else {
    Trace("binding: action rejected");
  }
}

void ShowContextMenu(GhosttyHost* host, LPARAM lparam) {
  if (!host || !host->child)
    return;
  HMENU menu = CreatePopupMenu();
  if (!menu)
    return;
  const bool has_selection =
      host->surface && ghostty_surface_has_selection(host->surface);
  AppendMenuW(menu, MF_STRING | (has_selection ? MF_ENABLED : MF_GRAYED),
              kCopyCommand, L"Copy");
  AppendMenuW(menu,
              MF_STRING | (IsClipboardFormatAvailable(CF_UNICODETEXT)
                               ? MF_ENABLED
                               : MF_GRAYED),
              kPasteCommand, L"Paste");
  POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  ClientToScreen(host->child, &point);
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, point.x, point.y, 0,
      host->child, nullptr);
  DestroyMenu(menu);
  if (command == kCopyCommand)
    InvokeBinding(host, "copy_to_clipboard");
  else if (command == kPasteCommand)
    InvokeBinding(host, "paste_from_clipboard");
}

LRESULT CALLBACK TerminalWindowProc(HWND window,
                                    UINT message,
                                    WPARAM wparam,
                                    LPARAM lparam) {
  GhosttyHost* host = reinterpret_cast<GhosttyHost*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    host = static_cast<GhosttyHost*>(create->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(host));
  }

  if (!host)
    return DefWindowProcW(window, message, wparam, lparam);

  switch (message) {
    case kWakeupMessage:
      if (!host->closing.load(std::memory_order_acquire) && host->app)
        ghostty_app_tick(host->app);
      return 0;
    case WM_SIZE:
    case WM_DPICHANGED_AFTERPARENT:
      UpdateSurfaceMetrics(host);
      if (host->surface)
        ghostty_surface_refresh(host->surface);
      return 0;
    case WM_SHOWWINDOW:
      if (host->surface)
        ghostty_surface_set_occlusion(host->surface, wparam != 0);
      return 0;
    case WM_SETFOCUS:
      if (host->app)
        ghostty_app_set_focus(host->app, true);
      if (host->surface)
        ghostty_surface_set_focus(host->surface, true);
      return 0;
    case WM_KILLFOCUS:
      host->modifier_latch = GHOSTTY_MODS_NONE;
      if (host->surface)
        ghostty_surface_set_focus(host->surface, false);
      if (host->app)
        ghostty_app_set_focus(host->app, false);
      return 0;
    case WM_LBUTTONDOWN:
      SetFocus(window);
      SetCapture(window);
      host->left_captured = true;
      SendMousePosition(host, lparam);
      if (host->surface)
        ghostty_surface_mouse_button(host->surface, GHOSTTY_MOUSE_PRESS,
                                     GHOSTTY_MOUSE_LEFT,
                                     CurrentModifiers(host));
      return 0;
    case WM_LBUTTONUP:
      SendMousePosition(host, lparam);
      if (host->surface)
        ghostty_surface_mouse_button(host->surface, GHOSTTY_MOUSE_RELEASE,
                                     GHOSTTY_MOUSE_LEFT,
                                     CurrentModifiers(host));
      if (host->left_captured) {
        ReleaseCapture();
        host->left_captured = false;
      }
      return 0;
    case WM_RBUTTONDOWN:
      SetFocus(window);
      SendMousePosition(host, lparam);
      host->right_captured =
          host->surface && ghostty_surface_mouse_captured(host->surface);
      if (host->right_captured) {
        SetCapture(window);
        ghostty_surface_mouse_button(host->surface, GHOSTTY_MOUSE_PRESS,
                                     GHOSTTY_MOUSE_RIGHT,
                                     CurrentModifiers(host));
      } else {
        ShowContextMenu(host, lparam);
      }
      return 0;
    case WM_RBUTTONUP:
      if (host->right_captured && host->surface) {
        SendMousePosition(host, lparam);
        ghostty_surface_mouse_button(host->surface, GHOSTTY_MOUSE_RELEASE,
                                     GHOSTTY_MOUSE_RIGHT,
                                     CurrentModifiers(host));
        ReleaseCapture();
        host->right_captured = false;
      }
      return 0;
    case WM_MOUSEMOVE:
      SendMousePosition(host, lparam);
      return 0;
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL:
      if (host->surface) {
        const double delta =
            static_cast<double>(GET_WHEEL_DELTA_WPARAM(wparam)) / WHEEL_DELTA;
        ghostty_surface_mouse_scroll(
            host->surface, message == WM_MOUSEHWHEEL ? delta : 0.0,
            message == WM_MOUSEWHEEL ? delta : 0.0, 0);
      }
      return 0;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
      // Alt+Tab belongs to Windows. Do not leak the Tab press into the shell
      // if the system sends the child HWND a system-key message first.
      if (message == WM_SYSKEYDOWN && wparam == VK_TAB)
        return 0;
      UpdateModifierLatch(host, wparam, lparam, true);
      // Windows delivers committed printable text through WM_CHAR. Sending
      // the physical key as well would duplicate unshifted digits for OEM
      // punctuation (for example '%' becoming '5'). Command chords still go
      // through Ghostty's key binding path.
      if (IsTextProducingKey(wparam) && !HasCommandModifier(host))
        return 0;
      SendKey(host, (lparam & (1LL << 30)) ? GHOSTTY_ACTION_REPEAT
                                          : GHOSTTY_ACTION_PRESS,
              wparam, lparam);
      return 0;
    case WM_KEYUP:
    case WM_SYSKEYUP:
      if (message == WM_SYSKEYUP && wparam == VK_TAB)
        return 0;
      if (IsTextProducingKey(wparam) && !HasCommandModifier(host)) {
        UpdateModifierLatch(host, wparam, lparam, false);
        return 0;
      }
      SendKey(host, GHOSTTY_ACTION_RELEASE, wparam, lparam);
      UpdateModifierLatch(host, wparam, lparam, false);
      return 0;
    case WM_CHAR:
      if (wparam >= 0x20 && wparam != 0x7f)
        SendUtf16Character(host, static_cast<wchar_t>(wparam));
      return 0;
    case WM_UNICHAR:
      if (wparam == UNICODE_NOCHAR)
        return TRUE;
      if (wparam <= 0xffff) {
        SendUtf16Character(host, static_cast<wchar_t>(wparam));
      } else if (wparam <= 0x10ffff) {
        const uint32_t codepoint = static_cast<uint32_t>(wparam) - 0x10000;
        SendUtf16Character(host,
                           static_cast<wchar_t>(0xd800 + (codepoint >> 10)));
        SendUtf16Character(host,
                           static_cast<wchar_t>(0xdc00 + (codepoint & 0x3ff)));
      }
      return 0;
    case WM_SYSCHAR:
      return 0;
    case WM_SETCURSOR:
      SetCursor(LoadCursorW(nullptr, MAKEINTRESOURCEW(32513)));
      return TRUE;
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint = {};
      BeginPaint(window, &paint);
      EndPaint(window, &paint);
      if (host->surface)
        ghostty_surface_refresh(host->surface);
      return 0;
    }
    case WM_NCDESTROY:
      SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      return DefWindowProcW(window, message, wparam, lparam);
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

bool EnsureWindowClass() {
  static std::once_flag once;
  static bool success = false;
  std::call_once(once, [] {
    WNDCLASSEXW window_class = {};
    window_class.cbSize = sizeof(window_class);
    window_class.style = CS_OWNDC | CS_HREDRAW | CS_VREDRAW;
    window_class.lpfnWndProc = TerminalWindowProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32513));
    window_class.hbrBackground =
        static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    window_class.lpszClassName = kTerminalWindowClass;
    success = RegisterClassExW(&window_class) != 0 ||
              GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
  });
  return success;
}

void DestroyHostResources(GhosttyHost* host) {
  if (!host || host->closing.exchange(true, std::memory_order_acq_rel))
    return;
  Trace("destroy: entered");
  if (host->surface) {
    ghostty_surface_set_focus(host->surface, false);
    Trace("destroy: freeing surface");
    ghostty_surface_free(host->surface);
    Trace("destroy: surface freed");
    host->surface = nullptr;
  }
  if (host->app) {
    Trace("destroy: freeing app");
    ghostty_app_free(host->app);
    Trace("destroy: app freed");
    host->app = nullptr;
  }
  if (host->config) {
    Trace("destroy: freeing config");
    ghostty_config_free(host->config);
    Trace("destroy: config freed");
    host->config = nullptr;
  }
  Trace("destroy: freeing WGL");
  DestroyWgl(host);
  Trace("destroy: WGL freed");
  if (host->child) {
    SetWindowLongPtrW(host->child, GWLP_USERDATA, 0);
    DestroyWindow(host->child);
    host->child = nullptr;
  }
  host->parent = nullptr;
  Trace("destroy: complete");
}

void FinalizeHost(napi_env, void* data, void*) {
  auto* host = static_cast<GhosttyHost*>(data);
  DestroyHostResources(host);
  delete host;
}

napi_value Create(napi_env env, napi_callback_info info) {
  Trace("create: entered");
  size_t argc = 2;
  napi_value args[2];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc != 2) {
    Throw(env, "create expects a native window handle and bounds/options");
    return nullptr;
  }

  void* handle_data = nullptr;
  size_t handle_size = 0;
  if (napi_get_buffer_info(env, args[0], &handle_data, &handle_size) !=
          napi_ok ||
      handle_size != sizeof(HWND)) {
    Throw(env,
          "Expected BrowserWindow.getNativeWindowHandle() on 64-bit Windows");
    return nullptr;
  }
  HWND parent = *static_cast<HWND*>(handle_data);
  if (!parent || !IsWindow(parent)) {
    Throw(env, "Electron returned an invalid parent HWND");
    return nullptr;
  }

  double x = 0;
  double y = 0;
  double width = 800;
  double height = 600;
  if (!GetNamedDouble(env, args[1], "x", &x) ||
      !GetNamedDouble(env, args[1], "y", &y) ||
      !GetNamedDouble(env, args[1], "width", &width) ||
      !GetNamedDouble(env, args[1], "height", &height)) {
    Throw(env, "Bounds must contain numeric x, y, width, and height");
    return nullptr;
  }

  if (!EnsureWindowClass() || !EnsureGhosttyInitialized()) {
    Throw(env, "Unable to initialize the Ghostty Windows host");
    return nullptr;
  }
  Trace("create: libghostty initialized");

  Trace("create: allocating host");
  auto* host = new GhosttyHost();
  Trace("create: host allocated");
  InitializeCriticalSection(&host->context_lock);
  host->context_lock_initialized = true;
  host->parent = parent;
  Trace("create: creating child HWND");
  host->child = CreateWindowExW(
      0, kTerminalWindowClass, L"Native libghostty terminal",
      WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
      DipToPixel(parent, x), DipToPixel(parent, y),
      DipToPixel(parent, width), DipToPixel(parent, height), parent, nullptr,
      GetModuleHandleW(nullptr), host);
  if (!host->child) {
    DestroyHostResources(host);
    delete host;
    Throw(env, "CreateWindowEx failed for the terminal child HWND");
    return nullptr;
  }
  Trace("create: child HWND created");

  std::string wgl_error;
  if (!InitializeWgl(host, &wgl_error)) {
    DestroyHostResources(host);
    delete host;
    Throw(env, wgl_error.c_str());
    return nullptr;
  }
  Trace("create: WGL context created");

  host->config = ghostty_config_new();
  if (!host->config) {
    DestroyHostResources(host);
    delete host;
    Throw(env, "ghostty_config_new failed");
    return nullptr;
  }
  ghostty_config_load_default_files(host->config);
  ghostty_config_finalize(host->config);
  Trace("create: config finalized");

  ghostty_runtime_config_s runtime = {};
  runtime.userdata = host;
  runtime.supports_selection_clipboard = false;
  runtime.wakeup_cb = Wakeup;
  runtime.action_cb = Action;
  runtime.read_clipboard_cb = ReadClipboard;
  runtime.confirm_read_clipboard_cb = ConfirmReadClipboard;
  runtime.write_clipboard_cb = WriteClipboard;
  runtime.close_surface_cb = CloseSurface;
  host->app = ghostty_app_new(&runtime, host->config);
  if (!host->app) {
    DestroyHostResources(host);
    delete host;
    Throw(env, "ghostty_app_new failed");
    return nullptr;
  }
  Trace("create: app created");

  const std::string working_directory =
      GetNamedString(env, args[1], "workingDirectory");
  const std::string command = GetNamedString(env, args[1], "command");
  ghostty_surface_config_s surface = ghostty_surface_config_new();
  surface.platform_tag = GHOSTTY_PLATFORM_OPENGL;
  surface.platform.opengl.userdata = host;
  surface.platform.opengl.make_current = WglMakeCurrent;
  surface.platform.opengl.clear_current = WglClearCurrent;
  surface.platform.opengl.get_proc_address = WglGetProcAddress;
  surface.platform.opengl.swap_buffers = WglSwapBuffers;
  surface.userdata = host;
  const UINT dpi = GetDpiForWindow(host->child);
  surface.scale_factor = dpi > 0 ? static_cast<double>(dpi) / 96.0 : 1.0;
  surface.working_directory =
      working_directory.empty() ? nullptr : working_directory.c_str();
  surface.command = command.empty() ? nullptr : command.c_str();
  host->surface = ghostty_surface_new(host->app, &surface);
  if (!host->surface) {
    DestroyHostResources(host);
    delete host;
    Throw(env, "ghostty_surface_new failed for the WGL surface");
    return nullptr;
  }
  Trace("create: surface created");

  host->closing.store(false, std::memory_order_release);
  ghostty_app_set_focus(host->app, true);
  ghostty_surface_set_focus(host->surface, true);
  UpdateSurfaceMetrics(host);
  SetWindowPos(host->child, HWND_TOP, DipToPixel(parent, x),
               DipToPixel(parent, y), DipToPixel(parent, width),
               DipToPixel(parent, height),
               SWP_SHOWWINDOW | SWP_NOACTIVATE);

  napi_value external;
  napi_create_external(env, host, FinalizeHost, nullptr, &external);
  Trace("create: complete");
  return external;
}

GhosttyHost* GetHost(napi_env env, napi_value value) {
  GhosttyHost* host = nullptr;
  if (napi_get_value_external(env, value, reinterpret_cast<void**>(&host)) !=
          napi_ok ||
      !host) {
    return nullptr;
  }
  return host;
}

napi_value SetBounds(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc != 2) {
    Throw(env, "setBounds expects a terminal handle and bounds");
    return nullptr;
  }
  GhosttyHost* host = GetHost(env, args[0]);
  if (!host || host->closing.load(std::memory_order_acquire) || !host->child) {
    Throw(env, "Invalid terminal handle");
    return nullptr;
  }
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
  if (!GetNamedDouble(env, args[1], "x", &x) ||
      !GetNamedDouble(env, args[1], "y", &y) ||
      !GetNamedDouble(env, args[1], "width", &width) ||
      !GetNamedDouble(env, args[1], "height", &height)) {
    Throw(env, "Bounds must contain numeric x, y, width, and height");
    return nullptr;
  }
  SetWindowPos(host->child, HWND_TOP, DipToPixel(host->parent, x),
               DipToPixel(host->parent, y), DipToPixel(host->parent, width),
               DipToPixel(host->parent, height),
               SWP_SHOWWINDOW | SWP_NOACTIVATE);
  UpdateSurfaceMetrics(host);
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  return undefined;
}

napi_value SendText(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc != 2) {
    Throw(env, "sendText expects a terminal handle and UTF-8 text");
    return nullptr;
  }
  GhosttyHost* host = GetHost(env, args[0]);
  if (!host || host->closing.load(std::memory_order_acquire) ||
      !host->surface) {
    Throw(env, "Invalid terminal handle");
    return nullptr;
  }
  size_t length = 0;
  if (napi_get_value_string_utf8(env, args[1], nullptr, 0, &length) !=
      napi_ok) {
    Throw(env, "sendText text must be a string");
    return nullptr;
  }
  std::string text(length + 1, '\0');
  if (napi_get_value_string_utf8(env, args[1], text.data(), text.size(),
                                 &length) != napi_ok) {
    Throw(env, "Unable to read sendText text");
    return nullptr;
  }
  text.resize(length);
  ghostty_surface_text_input(host->surface, text.data(), text.size());
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  return undefined;
}

napi_value Focus(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc != 1) {
    Throw(env, "focus expects a terminal handle");
    return nullptr;
  }
  GhosttyHost* host = GetHost(env, args[0]);
  if (!host || host->closing.load(std::memory_order_acquire) || !host->child) {
    Throw(env, "Invalid terminal handle");
    return nullptr;
  }
  SetFocus(host->child);
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  return undefined;
}

void SetNamedString(napi_env env,
                    napi_value object,
                    const char* name,
                    const std::string& value) {
  napi_value result;
  napi_create_string_utf8(env, value.c_str(), value.size(), &result);
  napi_set_named_property(env, object, name, result);
}

void SetNamedBool(napi_env env,
                  napi_value object,
                  const char* name,
                  bool value) {
  napi_value result;
  napi_get_boolean(env, value, &result);
  napi_set_named_property(env, object, name, result);
}

napi_value Diagnostics(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc != 1) {
    Throw(env, "diagnostics expects a terminal handle");
    return nullptr;
  }
  GhosttyHost* host = GetHost(env, args[0]);
  if (!host) {
    Throw(env, "Invalid terminal handle");
    return nullptr;
  }
  napi_value result;
  napi_create_object(env, &result);
  SetNamedBool(env, result, "realLibghostty", host->surface != nullptr);
  SetNamedBool(env, result, "rendererHealthy",
               host->renderer_healthy.load(std::memory_order_acquire));
  SetNamedString(env, result, "renderer", "libghostty/OpenGL/WGL");
  SetNamedString(env, result, "glVersion", host->gl_version);
  SetNamedString(env, result, "pixelFormatApi", host->pixel_format_api);
  napi_value swaps;
  napi_create_bigint_uint64(env, host->swaps.load(std::memory_order_relaxed),
                            &swaps);
  napi_set_named_property(env, result, "swaps", swaps);
  return result;
}

napi_value Destroy(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc != 1) {
    Throw(env, "destroy expects a terminal handle");
    return nullptr;
  }
  GhosttyHost* host = GetHost(env, args[0]);
  if (!host) {
    Throw(env, "Invalid terminal handle");
    return nullptr;
  }
  DestroyHostResources(host);
  napi_value undefined;
  napi_get_undefined(env, &undefined);
  return undefined;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
      {"create", nullptr, Create, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"setBounds", nullptr, SetBounds, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"sendText", nullptr, SendText, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"focus", nullptr, Focus, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"diagnostics", nullptr, Diagnostics, nullptr, nullptr, nullptr,
       napi_default, nullptr},
      {"destroy", nullptr, Destroy, nullptr, nullptr, nullptr, napi_default,
       nullptr},
  };
  napi_define_properties(env, exports, std::size(properties), properties);
  return exports;
}

}  // namespace

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
