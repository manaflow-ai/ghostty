#include "imgui.h"

#include <mutex>

// This file contains custom extensions for functionality that isn't
// properly supported by Dear Bindings yet. Namely:
// https://github.com/dearimgui/dear_bindings/issues/55

// Wrap this in a namespace to keep it separate from the C++ API
namespace cimgui
{
#include "dcimgui.h"
}

extern "C"
{
CIMGUI_API void ImFontConfig_ImFontConfig(cimgui::ImFontConfig* self)
{
    static_assert(sizeof(cimgui::ImFontConfig) == sizeof(::ImFontConfig), "ImFontConfig size mismatch");
    static_assert(alignof(cimgui::ImFontConfig) == alignof(::ImFontConfig), "ImFontConfig alignment mismatch");
    ::ImFontConfig defaults;
    *reinterpret_cast<::ImFontConfig*>(self) = defaults;
}

CIMGUI_API void ImGuiStyle_ImGuiStyle(cimgui::ImGuiStyle* self)
{
    static_assert(sizeof(cimgui::ImGuiStyle) == sizeof(::ImGuiStyle), "ImGuiStyle size mismatch");
    static_assert(alignof(cimgui::ImGuiStyle) == alignof(::ImGuiStyle), "ImGuiStyle alignment mismatch");
    ::ImGuiStyle defaults;
    *reinterpret_cast<::ImGuiStyle*>(self) = defaults;
}

// Track every OpenGL3 backend because imgl3w's loader state is process-wide,
// while Dear ImGui stores renderer backend state per ImGui context.
#ifndef IMGUI_DISABLE
#if __has_include("backends/imgui_impl_opengl3.h")
#ifdef ZIGPKG_IMGUI_ENABLE_OPENGL3
#include "backends/imgui_impl_opengl3.h"
#include "backends/imgui_impl_opengl3_loader.h"

namespace
{
std::mutex imgui_opengl3_loader_mutex;
unsigned int imgui_opengl3_backend_users = 0;
}

CIMGUI_API bool ImGui_ImplOpenGL3_InitWithLoaderTracking(const char* glsl_version)
{
    const std::lock_guard<std::mutex> lock(imgui_opengl3_loader_mutex);
    if (!::ImGui_ImplOpenGL3_Init(glsl_version))
        return false;

    imgui_opengl3_backend_users++;
    return true;
}

CIMGUI_API bool ImGui_ImplOpenGL3_ShutdownWithLoaderTracking()
{
    const std::lock_guard<std::mutex> lock(imgui_opengl3_loader_mutex);
    if (imgui_opengl3_backend_users == 0)
        return false;

    ::ImGui_ImplOpenGL3_Shutdown();
    imgui_opengl3_backend_users--;

    if (imgui_opengl3_backend_users == 0)
    {
        // Shutdown closes the loader handles but leaves stale pointers. Clear
        // them so the next first backend performs a complete loader init.
        memset(&imgl3wProcs, 0, sizeof(imgl3wProcs));
        return true;
    }

    // Other ImGui contexts still have live GL objects. Shutdown closed the
    // process-wide loader, so restore its handles and function table before
    // another context renders or shuts down.
    if (imgl3wInit() != GL3W_OK)
    {
        memset(&imgl3wProcs, 0, sizeof(imgl3wProcs));
        return false;
    }

    return true;
}

CIMGUI_API bool ImGui_ImplOpenGL3_AbandonLoaderTracking()
{
    const std::lock_guard<std::mutex> lock(imgui_opengl3_loader_mutex);
    if (imgui_opengl3_backend_users == 0)
        return false;

    imgui_opengl3_backend_users--;
    if (imgui_opengl3_backend_users == 0)
    {
        // The context is gone, so per-context GL objects cannot be deleted.
        // Loader handles are process state and can still be released safely.
        imgl3wShutdown();
        memset(&imgl3wProcs, 0, sizeof(imgl3wProcs));
    }

    return true;
}
#endif // ZIGPKG_IMGUI_ENABLE_OPENGL3
#endif // __has_include("backends/imgui_impl_opengl3.h")
#endif // IMGUI_DISABLE

}
