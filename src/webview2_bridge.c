#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef struct ICoreWebView2 ICoreWebView2;
typedef struct ICoreWebView2Controller ICoreWebView2Controller;
typedef struct ICoreWebView2Environment ICoreWebView2Environment;
typedef struct ICoreWebView2AcceleratorKeyPressedEventArgs ICoreWebView2AcceleratorKeyPressedEventArgs;
typedef struct ICoreWebView2AcceleratorKeyPressedEventHandler ICoreWebView2AcceleratorKeyPressedEventHandler;
typedef struct ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler;
typedef struct ICoreWebView2CreateCoreWebView2ControllerCompletedHandler ICoreWebView2CreateCoreWebView2ControllerCompletedHandler;

typedef HRESULT (WINAPI *CreateCoreWebView2EnvironmentWithOptionsFn)(
    LPCWSTR browserExecutableFolder,
    LPCWSTR userDataFolder,
    void *environmentOptions,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *environmentCreatedHandler);
typedef HRESULT (WINAPI *GetAvailableCoreWebView2BrowserVersionStringFn)(
    LPCWSTR browserExecutableFolder,
    LPWSTR *versionInfo);

typedef struct ICoreWebView2EnvironmentVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ICoreWebView2Environment *This, REFIID riid, void **ppvObject);
    ULONG (STDMETHODCALLTYPE *AddRef)(ICoreWebView2Environment *This);
    ULONG (STDMETHODCALLTYPE *Release)(ICoreWebView2Environment *This);
    HRESULT (STDMETHODCALLTYPE *CreateCoreWebView2Controller)(
        ICoreWebView2Environment *This,
        HWND parentWindow,
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *handler);
} ICoreWebView2EnvironmentVtbl;

struct ICoreWebView2Environment {
    const ICoreWebView2EnvironmentVtbl *lpVtbl;
};

typedef struct ICoreWebView2ControllerVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ICoreWebView2Controller *This, REFIID riid, void **ppvObject);
    ULONG (STDMETHODCALLTYPE *AddRef)(ICoreWebView2Controller *This);
    ULONG (STDMETHODCALLTYPE *Release)(ICoreWebView2Controller *This);
    HRESULT (STDMETHODCALLTYPE *get_IsVisible)(ICoreWebView2Controller *This, BOOL *isVisible);
    HRESULT (STDMETHODCALLTYPE *put_IsVisible)(ICoreWebView2Controller *This, BOOL isVisible);
    HRESULT (STDMETHODCALLTYPE *get_Bounds)(ICoreWebView2Controller *This, RECT *bounds);
    HRESULT (STDMETHODCALLTYPE *put_Bounds)(ICoreWebView2Controller *This, RECT bounds);
    HRESULT (STDMETHODCALLTYPE *get_ZoomFactor)(ICoreWebView2Controller *This, double *zoomFactor);
    HRESULT (STDMETHODCALLTYPE *put_ZoomFactor)(ICoreWebView2Controller *This, double zoomFactor);
    HRESULT (STDMETHODCALLTYPE *add_ZoomFactorChanged)(ICoreWebView2Controller *This, void *eventHandler, void *token);
    HRESULT (STDMETHODCALLTYPE *remove_ZoomFactorChanged)(ICoreWebView2Controller *This, int64_t token);
    HRESULT (STDMETHODCALLTYPE *SetBoundsAndZoomFactor)(ICoreWebView2Controller *This, RECT bounds, double zoomFactor);
    HRESULT (STDMETHODCALLTYPE *MoveFocus)(ICoreWebView2Controller *This, int reason);
    HRESULT (STDMETHODCALLTYPE *add_MoveFocusRequested)(ICoreWebView2Controller *This, void *eventHandler, void *token);
    HRESULT (STDMETHODCALLTYPE *remove_MoveFocusRequested)(ICoreWebView2Controller *This, int64_t token);
    HRESULT (STDMETHODCALLTYPE *add_GotFocus)(ICoreWebView2Controller *This, void *eventHandler, void *token);
    HRESULT (STDMETHODCALLTYPE *remove_GotFocus)(ICoreWebView2Controller *This, int64_t token);
    HRESULT (STDMETHODCALLTYPE *add_LostFocus)(ICoreWebView2Controller *This, void *eventHandler, void *token);
    HRESULT (STDMETHODCALLTYPE *remove_LostFocus)(ICoreWebView2Controller *This, int64_t token);
    HRESULT (STDMETHODCALLTYPE *add_AcceleratorKeyPressed)(
        ICoreWebView2Controller *This,
        ICoreWebView2AcceleratorKeyPressedEventHandler *eventHandler,
        void *token);
    HRESULT (STDMETHODCALLTYPE *remove_AcceleratorKeyPressed)(ICoreWebView2Controller *This, int64_t token);
    HRESULT (STDMETHODCALLTYPE *get_ParentWindow)(ICoreWebView2Controller *This, HWND *parentWindow);
    HRESULT (STDMETHODCALLTYPE *put_ParentWindow)(ICoreWebView2Controller *This, HWND parentWindow);
    HRESULT (STDMETHODCALLTYPE *NotifyParentWindowPositionChanged)(ICoreWebView2Controller *This);
    HRESULT (STDMETHODCALLTYPE *Close)(ICoreWebView2Controller *This);
    HRESULT (STDMETHODCALLTYPE *get_CoreWebView2)(ICoreWebView2Controller *This, ICoreWebView2 **coreWebView2);
} ICoreWebView2ControllerVtbl;

struct ICoreWebView2Controller {
    const ICoreWebView2ControllerVtbl *lpVtbl;
};

typedef struct ICoreWebView2Vtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ICoreWebView2 *This, REFIID riid, void **ppvObject);
    ULONG (STDMETHODCALLTYPE *AddRef)(ICoreWebView2 *This);
    ULONG (STDMETHODCALLTYPE *Release)(ICoreWebView2 *This);
    HRESULT (STDMETHODCALLTYPE *get_Settings)(ICoreWebView2 *This, void **settings);
    HRESULT (STDMETHODCALLTYPE *get_Source)(ICoreWebView2 *This, LPWSTR *uri);
    HRESULT (STDMETHODCALLTYPE *Navigate)(ICoreWebView2 *This, LPCWSTR uri);
    HRESULT (STDMETHODCALLTYPE *NavigateToString)(ICoreWebView2 *This, LPCWSTR htmlContent);
} ICoreWebView2Vtbl;

struct ICoreWebView2 {
    const ICoreWebView2Vtbl *lpVtbl;
};

typedef struct ICoreWebView2AcceleratorKeyPressedEventArgsVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ICoreWebView2AcceleratorKeyPressedEventArgs *This, REFIID riid, void **ppvObject);
    ULONG (STDMETHODCALLTYPE *AddRef)(ICoreWebView2AcceleratorKeyPressedEventArgs *This);
    ULONG (STDMETHODCALLTYPE *Release)(ICoreWebView2AcceleratorKeyPressedEventArgs *This);
    HRESULT (STDMETHODCALLTYPE *get_KeyEventKind)(ICoreWebView2AcceleratorKeyPressedEventArgs *This, int *keyEventKind);
    HRESULT (STDMETHODCALLTYPE *get_VirtualKey)(ICoreWebView2AcceleratorKeyPressedEventArgs *This, UINT *virtualKey);
    HRESULT (STDMETHODCALLTYPE *get_KeyEventLParam)(ICoreWebView2AcceleratorKeyPressedEventArgs *This, INT *lParam);
    HRESULT (STDMETHODCALLTYPE *get_PhysicalKeyStatus)(ICoreWebView2AcceleratorKeyPressedEventArgs *This, void *physicalKeyStatus);
    HRESULT (STDMETHODCALLTYPE *get_Handled)(ICoreWebView2AcceleratorKeyPressedEventArgs *This, BOOL *handled);
    HRESULT (STDMETHODCALLTYPE *put_Handled)(ICoreWebView2AcceleratorKeyPressedEventArgs *This, BOOL handled);
} ICoreWebView2AcceleratorKeyPressedEventArgsVtbl;

struct ICoreWebView2AcceleratorKeyPressedEventArgs {
    const ICoreWebView2AcceleratorKeyPressedEventArgsVtbl *lpVtbl;
};

typedef struct ICoreWebView2AcceleratorKeyPressedEventHandlerVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ICoreWebView2AcceleratorKeyPressedEventHandler *This, REFIID riid, void **ppvObject);
    ULONG (STDMETHODCALLTYPE *AddRef)(ICoreWebView2AcceleratorKeyPressedEventHandler *This);
    ULONG (STDMETHODCALLTYPE *Release)(ICoreWebView2AcceleratorKeyPressedEventHandler *This);
    HRESULT (STDMETHODCALLTYPE *Invoke)(
        ICoreWebView2AcceleratorKeyPressedEventHandler *This,
        ICoreWebView2Controller *sender,
        ICoreWebView2AcceleratorKeyPressedEventArgs *args);
} ICoreWebView2AcceleratorKeyPressedEventHandlerVtbl;

struct ICoreWebView2AcceleratorKeyPressedEventHandler {
    const ICoreWebView2AcceleratorKeyPressedEventHandlerVtbl *lpVtbl;
};

typedef struct ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This, REFIID riid, void **ppvObject);
    ULONG (STDMETHODCALLTYPE *AddRef)(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This);
    ULONG (STDMETHODCALLTYPE *Release)(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This);
    HRESULT (STDMETHODCALLTYPE *Invoke)(
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This,
        HRESULT errorCode,
        ICoreWebView2Environment *result);
} ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl;

struct ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler {
    const ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl *lpVtbl;
};

typedef struct ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This, REFIID riid, void **ppvObject);
    ULONG (STDMETHODCALLTYPE *AddRef)(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This);
    ULONG (STDMETHODCALLTYPE *Release)(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This);
    HRESULT (STDMETHODCALLTYPE *Invoke)(
        ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This,
        HRESULT errorCode,
        ICoreWebView2Controller *result);
} ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl;

struct ICoreWebView2CreateCoreWebView2ControllerCompletedHandler {
    const ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl *lpVtbl;
};

typedef struct PhanttyWebView2Browser PhanttyWebView2Browser;

typedef struct EnvCompletedHandler {
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler iface;
    LONG refs;
    PhanttyWebView2Browser *browser;
} EnvCompletedHandler;

typedef struct ControllerCompletedHandler {
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler iface;
    LONG refs;
    PhanttyWebView2Browser *browser;
} ControllerCompletedHandler;

typedef struct AcceleratorKeyPressedHandler {
    ICoreWebView2AcceleratorKeyPressedEventHandler iface;
    LONG refs;
    PhanttyWebView2Browser *browser;
} AcceleratorKeyPressedHandler;

typedef struct EventRegistrationToken {
    int64_t value;
} EventRegistrationToken;

struct PhanttyWebView2Browser {
    LONG refs;
    HWND parent;
    RECT bounds;
    BOOL visible;
    BOOL closing;
    BOOL com_initialized;
    HRESULT last_error;
    HMODULE loader;
    ICoreWebView2Environment *environment;
    ICoreWebView2Controller *controller;
    ICoreWebView2 *webview;
    EnvCompletedHandler env_handler;
    ControllerCompletedHandler controller_handler;
    AcceleratorKeyPressedHandler accelerator_handler;
    BOOL env_async_pending;
    BOOL controller_async_pending;
    EventRegistrationToken accelerator_token;
    BOOL accelerator_registered;
    WCHAR pending_url[2048];
};

static void browser_release(PhanttyWebView2Browser *browser);

static void browser_add_ref(PhanttyWebView2Browser *browser) {
    if (browser) InterlockedIncrement(&browser->refs);
}

static void copy_url(WCHAR *dst, size_t dst_len, const WCHAR *src) {
    if (!dst || dst_len == 0) return;
    dst[0] = 0;
    if (!src) return;
    wcsncpy(dst, src, dst_len - 1);
    dst[dst_len - 1] = 0;
}

static ULONG STDMETHODCALLTYPE env_AddRef(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This);
static ULONG STDMETHODCALLTYPE controller_AddRef(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This);
static ULONG STDMETHODCALLTYPE accelerator_AddRef(ICoreWebView2AcceleratorKeyPressedEventHandler *This);

static HRESULT handler_qi(void *This, void **ppvObject) {
    if (!ppvObject) return E_POINTER;
    *ppvObject = This;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE env_QueryInterface(
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This,
    REFIID riid,
    void **ppvObject) {
    (void)riid;
    HRESULT hr = handler_qi(This, ppvObject);
    if (SUCCEEDED(hr)) env_AddRef(This);
    return hr;
}

static ULONG STDMETHODCALLTYPE env_AddRef(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This) {
    EnvCompletedHandler *handler = (EnvCompletedHandler *)This;
    return (ULONG)InterlockedIncrement(&handler->refs);
}

static ULONG STDMETHODCALLTYPE env_Release(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This) {
    EnvCompletedHandler *handler = (EnvCompletedHandler *)This;
    LONG refs = InterlockedDecrement(&handler->refs);
    PhanttyWebView2Browser *browser = handler->browser;
    if (refs == 1 && browser && browser->env_async_pending) {
        browser->env_async_pending = FALSE;
        browser_release(browser);
    }
    return refs < 0 ? 0 : (ULONG)refs;
}

static HRESULT STDMETHODCALLTYPE controller_QueryInterface(
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This,
    REFIID riid,
    void **ppvObject) {
    (void)riid;
    HRESULT hr = handler_qi(This, ppvObject);
    if (SUCCEEDED(hr)) controller_AddRef(This);
    return hr;
}

static ULONG STDMETHODCALLTYPE controller_AddRef(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This) {
    ControllerCompletedHandler *handler = (ControllerCompletedHandler *)This;
    return (ULONG)InterlockedIncrement(&handler->refs);
}

static ULONG STDMETHODCALLTYPE controller_Release(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This) {
    ControllerCompletedHandler *handler = (ControllerCompletedHandler *)This;
    LONG refs = InterlockedDecrement(&handler->refs);
    PhanttyWebView2Browser *browser = handler->browser;
    if (refs == 1 && browser && browser->controller_async_pending) {
        browser->controller_async_pending = FALSE;
        browser_release(browser);
    }
    return refs < 0 ? 0 : (ULONG)refs;
}

static HRESULT STDMETHODCALLTYPE accelerator_QueryInterface(
    ICoreWebView2AcceleratorKeyPressedEventHandler *This,
    REFIID riid,
    void **ppvObject) {
    (void)riid;
    HRESULT hr = handler_qi(This, ppvObject);
    if (SUCCEEDED(hr)) accelerator_AddRef(This);
    return hr;
}

static ULONG STDMETHODCALLTYPE accelerator_AddRef(ICoreWebView2AcceleratorKeyPressedEventHandler *This) {
    AcceleratorKeyPressedHandler *handler = (AcceleratorKeyPressedHandler *)This;
    return (ULONG)InterlockedIncrement(&handler->refs);
}

static ULONG STDMETHODCALLTYPE accelerator_Release(ICoreWebView2AcceleratorKeyPressedEventHandler *This) {
    AcceleratorKeyPressedHandler *handler = (AcceleratorKeyPressedHandler *)This;
    LONG refs = InterlockedDecrement(&handler->refs);
    return refs < 0 ? 0 : (ULONG)refs;
}

static BOOL key_down(int vk) {
    return (GetKeyState(vk) & 0x8000) != 0;
}

static BOOL should_forward_host_shortcut(UINT virtual_key, BOOL ctrl, BOOL shift, BOOL alt) {
    if (ctrl && shift && !alt) {
        switch (virtual_key) {
            case 'B':
            case 'N':
            case 'O':
            case 'P':
            case 'T':
            case 'W':
            case 'Z':
            case VK_OEM_4: // [
            case VK_OEM_6: // ]
                return TRUE;
            default:
                return FALSE;
        }
    }

    if (ctrl && shift && alt) {
        switch (virtual_key) {
            case 'E':
                return TRUE;
            default:
                return FALSE;
        }
    }

    if (alt && !ctrl && !shift) {
        switch (virtual_key) {
            case VK_RETURN:
            case VK_LEFT:
            case VK_RIGHT:
            case VK_UP:
            case VK_DOWN:
                return TRUE;
            default:
                return FALSE;
        }
    }

    return FALSE;
}

static HRESULT STDMETHODCALLTYPE accelerator_Invoke(
    ICoreWebView2AcceleratorKeyPressedEventHandler *This,
    ICoreWebView2Controller *sender,
    ICoreWebView2AcceleratorKeyPressedEventArgs *args);

static HRESULT STDMETHODCALLTYPE env_Invoke(
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This,
    HRESULT errorCode,
    ICoreWebView2Environment *result);

static HRESULT STDMETHODCALLTYPE controller_Invoke(
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This,
    HRESULT errorCode,
    ICoreWebView2Controller *result);

static const ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl env_vtbl = {
    env_QueryInterface,
    env_AddRef,
    env_Release,
    env_Invoke,
};

static const ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl controller_vtbl = {
    controller_QueryInterface,
    controller_AddRef,
    controller_Release,
    controller_Invoke,
};

static const ICoreWebView2AcceleratorKeyPressedEventHandlerVtbl accelerator_vtbl = {
    accelerator_QueryInterface,
    accelerator_AddRef,
    accelerator_Release,
    accelerator_Invoke,
};

static HMODULE try_load_from_nuget(void) {
    WCHAR user_profile[MAX_PATH];
    DWORD profile_len = GetEnvironmentVariableW(L"USERPROFILE", user_profile, MAX_PATH);
    if (profile_len == 0 || profile_len >= MAX_PATH) return NULL;

    WCHAR base[MAX_PATH];
    if (wsprintfW(base, L"%s\\.nuget\\packages\\microsoft.web.webview2", user_profile) <= 0) {
        return NULL;
    }

    WCHAR pattern[MAX_PATH];
    if (wsprintfW(pattern, L"%s\\*", base) <= 0) return NULL;

    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileW(pattern, &data);
    if (find == INVALID_HANDLE_VALUE) return NULL;

    HMODULE result = NULL;
    do {
        if (!(data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
        if (wcscmp(data.cFileName, L".") == 0 || wcscmp(data.cFileName, L"..") == 0) continue;

        WCHAR candidate[MAX_PATH];
        if (wsprintfW(candidate, L"%s\\%s\\build\\native\\x64\\WebView2Loader.dll", base, data.cFileName) <= 0) {
            continue;
        }
        result = LoadLibraryW(candidate);
        if (result) break;
    } while (FindNextFileW(find, &data));

    FindClose(find);
    return result;
}

static HMODULE load_loader(void) {
    HMODULE loader = LoadLibraryW(L"WebView2Loader.dll");
    if (loader) return loader;
    return try_load_from_nuget();
}

int phantty_webview2_loader_available(void) {
    HMODULE loader = load_loader();
    if (!loader) return 0;

    FARPROC create_environment = GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions");
    GetAvailableCoreWebView2BrowserVersionStringFn get_version =
        (GetAvailableCoreWebView2BrowserVersionStringFn)GetProcAddress(loader, "GetAvailableCoreWebView2BrowserVersionString");
    if (!create_environment || !get_version) {
        FreeLibrary(loader);
        return 0;
    }

    LPWSTR version = NULL;
    HRESULT hr = get_version(NULL, &version);
    if (version) CoTaskMemFree(version);
    FreeLibrary(loader);
    return SUCCEEDED(hr) ? 1 : 0;
}

static void build_user_data_folder(WCHAR *buf, size_t len) {
    if (!buf || len == 0) return;
    buf[0] = 0;

    WCHAR local_app_data[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", local_app_data, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;

    WCHAR root[MAX_PATH];
    if (wsprintfW(root, L"%s\\phantty", local_app_data) <= 0) return;
    CreateDirectoryW(root, NULL);
    wsprintfW(buf, L"%s\\webview2", root);
    CreateDirectoryW(buf, NULL);
}

static void browser_apply_bounds(PhanttyWebView2Browser *browser) {
    if (!browser || browser->closing || !browser->controller) return;
    browser->controller->lpVtbl->put_Bounds(browser->controller, browser->bounds);
    browser->controller->lpVtbl->put_IsVisible(browser->controller, browser->visible);
    browser->controller->lpVtbl->NotifyParentWindowPositionChanged(browser->controller);
}

static void browser_release_webview_resources(PhanttyWebView2Browser *browser) {
    if (!browser) return;
    if (browser->controller) {
        if (browser->accelerator_registered) {
            browser->controller->lpVtbl->remove_AcceleratorKeyPressed(browser->controller, browser->accelerator_token.value);
            browser->accelerator_registered = FALSE;
        }
        browser->controller->lpVtbl->Close(browser->controller);
    }
    if (browser->webview) {
        browser->webview->lpVtbl->Release(browser->webview);
        browser->webview = NULL;
    }
    if (browser->controller) {
        browser->controller->lpVtbl->Release(browser->controller);
        browser->controller = NULL;
    }
    if (browser->environment) {
        browser->environment->lpVtbl->Release(browser->environment);
        browser->environment = NULL;
    }
}

static void browser_release(PhanttyWebView2Browser *browser) {
    if (!browser) return;
    if (InterlockedDecrement(&browser->refs) != 0) return;

    browser_release_webview_resources(browser);
    if (browser->loader) {
        FreeLibrary(browser->loader);
        browser->loader = NULL;
    }
    if (browser->com_initialized) {
        CoUninitialize();
        browser->com_initialized = FALSE;
    }
    free(browser);
}

static HRESULT STDMETHODCALLTYPE accelerator_Invoke(
    ICoreWebView2AcceleratorKeyPressedEventHandler *This,
    ICoreWebView2Controller *sender,
    ICoreWebView2AcceleratorKeyPressedEventArgs *args) {
    (void)sender;
    AcceleratorKeyPressedHandler *handler = (AcceleratorKeyPressedHandler *)This;
    PhanttyWebView2Browser *browser = handler->browser;
    if (!browser || browser->closing || !browser->parent || !args) return S_OK;

    int key_kind = 0;
    UINT virtual_key = 0;
    INT key_lparam = 0;
    if (FAILED(args->lpVtbl->get_KeyEventKind(args, &key_kind))) return S_OK;
    if (key_kind != 0 && key_kind != 2) return S_OK; // KEY_DOWN or SYSTEM_KEY_DOWN
    if (FAILED(args->lpVtbl->get_VirtualKey(args, &virtual_key))) return S_OK;
    (void)args->lpVtbl->get_KeyEventLParam(args, &key_lparam);

    BOOL ctrl = key_down(VK_CONTROL);
    BOOL shift = key_down(VK_SHIFT);
    BOOL alt = key_down(VK_MENU);
    if (!should_forward_host_shortcut(virtual_key, ctrl, shift, alt)) return S_OK;

    args->lpVtbl->put_Handled(args, TRUE);
    SetFocus(browser->parent);
    const UINT msg = alt ? WM_SYSKEYDOWN : WM_KEYDOWN;
    SendMessageW(browser->parent, msg, (WPARAM)virtual_key, (LPARAM)key_lparam);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE controller_Invoke(
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *This,
    HRESULT errorCode,
    ICoreWebView2Controller *result) {
    ControllerCompletedHandler *handler = (ControllerCompletedHandler *)This;
    PhanttyWebView2Browser *browser = handler->browser;
    if (!browser) return E_FAIL;
    browser->last_error = errorCode;
    if (browser->closing) {
        if (result) result->lpVtbl->Close(result);
        return S_OK;
    }
    if (FAILED(errorCode) || !result) return S_OK;

    browser->controller = result;
    browser->controller->lpVtbl->AddRef(browser->controller);
    browser_apply_bounds(browser);
    browser->last_error = browser->controller->lpVtbl->add_AcceleratorKeyPressed(
        browser->controller,
        &browser->accelerator_handler.iface,
        &browser->accelerator_token);
    browser->accelerator_registered = SUCCEEDED(browser->last_error);

    ICoreWebView2 *webview = NULL;
    HRESULT hr = browser->controller->lpVtbl->get_CoreWebView2(browser->controller, &webview);
    browser->last_error = hr;
    if (SUCCEEDED(hr) && webview) {
        browser->webview = webview;
        if (browser->pending_url[0] != 0) {
            browser->last_error = browser->webview->lpVtbl->Navigate(browser->webview, browser->pending_url);
        }
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE env_Invoke(
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *This,
    HRESULT errorCode,
    ICoreWebView2Environment *result) {
    EnvCompletedHandler *handler = (EnvCompletedHandler *)This;
    PhanttyWebView2Browser *browser = handler->browser;
    if (!browser) return E_FAIL;
    browser->last_error = errorCode;
    if (browser->closing || FAILED(errorCode) || !result) return S_OK;

    browser->environment = result;
    browser->environment->lpVtbl->AddRef(browser->environment);
    browser_add_ref(browser);
    browser->controller_async_pending = TRUE;
    browser->last_error = browser->environment->lpVtbl->CreateCoreWebView2Controller(
        browser->environment,
        browser->parent,
        &browser->controller_handler.iface);
    if (FAILED(browser->last_error) && browser->controller_async_pending) {
        browser->controller_async_pending = FALSE;
        browser_release(browser);
    }
    return S_OK;
}

PhanttyWebView2Browser *phantty_webview2_create(
    HWND parent,
    int left,
    int top,
    int right,
    int bottom,
    const WCHAR *initial_url) {
    HRESULT co_hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);

    PhanttyWebView2Browser *browser = (PhanttyWebView2Browser *)calloc(1, sizeof(PhanttyWebView2Browser));
    if (!browser) {
        if (SUCCEEDED(co_hr)) CoUninitialize();
        return NULL;
    }

    browser->refs = 1;
    browser->parent = parent;
    browser->bounds.left = left;
    browser->bounds.top = top;
    browser->bounds.right = right;
    browser->bounds.bottom = bottom;
    browser->visible = TRUE;
    browser->com_initialized = SUCCEEDED(co_hr);
    browser->last_error = co_hr;
    copy_url(browser->pending_url, sizeof(browser->pending_url) / sizeof(browser->pending_url[0]), initial_url);

    if (FAILED(co_hr)) {
        return browser;
    }

    browser->env_handler.iface.lpVtbl = &env_vtbl;
    browser->env_handler.refs = 1;
    browser->env_handler.browser = browser;
    browser->controller_handler.iface.lpVtbl = &controller_vtbl;
    browser->controller_handler.refs = 1;
    browser->controller_handler.browser = browser;
    browser->accelerator_handler.iface.lpVtbl = &accelerator_vtbl;
    browser->accelerator_handler.refs = 1;
    browser->accelerator_handler.browser = browser;

    browser->loader = load_loader();
    if (!browser->loader) {
        browser->last_error = HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
        return browser;
    }

    CreateCoreWebView2EnvironmentWithOptionsFn create_environment =
        (CreateCoreWebView2EnvironmentWithOptionsFn)GetProcAddress(browser->loader, "CreateCoreWebView2EnvironmentWithOptions");
    if (!create_environment) {
        browser->last_error = HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
        return browser;
    }

    WCHAR user_data[MAX_PATH];
    build_user_data_folder(user_data, sizeof(user_data) / sizeof(user_data[0]));
    browser_add_ref(browser);
    browser->env_async_pending = TRUE;
    browser->last_error = create_environment(
        NULL,
        user_data[0] ? user_data : NULL,
        NULL,
        &browser->env_handler.iface);
    if (FAILED(browser->last_error) && browser->env_async_pending) {
        browser->env_async_pending = FALSE;
        browser_release(browser);
    }
    return browser;
}

void phantty_webview2_set_bounds(PhanttyWebView2Browser *browser, int left, int top, int right, int bottom) {
    if (!browser || browser->closing) return;
    browser->bounds.left = left;
    browser->bounds.top = top;
    browser->bounds.right = right;
    browser->bounds.bottom = bottom;
    browser_apply_bounds(browser);
}

void phantty_webview2_set_visible(PhanttyWebView2Browser *browser, int visible) {
    if (!browser || browser->closing) return;
    browser->visible = visible ? TRUE : FALSE;
    browser_apply_bounds(browser);
}

void phantty_webview2_focus(PhanttyWebView2Browser *browser) {
    if (!browser || browser->closing || !browser->controller) return;
    browser->controller->lpVtbl->MoveFocus(browser->controller, 0);
}

void phantty_webview2_navigate(PhanttyWebView2Browser *browser, const WCHAR *url) {
    if (!browser || browser->closing) return;
    copy_url(browser->pending_url, sizeof(browser->pending_url) / sizeof(browser->pending_url[0]), url);
    if (browser->webview && browser->pending_url[0] != 0) {
        browser->last_error = browser->webview->lpVtbl->Navigate(browser->webview, browser->pending_url);
    }
}

int phantty_webview2_is_ready(PhanttyWebView2Browser *browser) {
    return browser && !browser->closing && browser->controller && browser->webview;
}

HRESULT phantty_webview2_last_error(PhanttyWebView2Browser *browser) {
    return browser ? browser->last_error : E_POINTER;
}

void phantty_webview2_destroy(PhanttyWebView2Browser *browser) {
    if (!browser) return;
    browser->closing = TRUE;
    browser_release_webview_resources(browser);
    browser_release(browser);
}
