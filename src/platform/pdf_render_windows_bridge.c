// WinRT Windows.Data.Pdf rasterizer bridge (Win10+ system component).
//
// All WinRT/COM entry points are loaded dynamically (combase/shlwapi/shcore),
// so no new import libraries are required. Async operations are observed by
// polling IAsyncInfo::get_Status from the (non-UI) preview job thread, which
// avoids implementing COM completion-handler objects in C.
//
// Interface IIDs and vtable slot orders below were verified against the
// Windows SDK header windows.data.pdf.h (10.0.16299.0):
//   IPdfDocumentStatics  {433A0B5F-C007-4788-90F2-08143D922599}
//     LoadFromFileAsync, LoadFromFileWithPasswordAsync,
//     LoadFromStreamAsync, LoadFromStreamWithPasswordAsync
//   IPdfDocument         {AC7EBEDD-80FA-4089-846E-81B77FF5A86C}
//     GetPage, get_PageCount, get_IsPasswordProtected
//   IPdfPage             {9DB4B0C8-5320-4CFC-AD76-493FDAD0E594}
//     RenderToStreamAsync, RenderWithOptionsToStreamAsync, PreparePageAsync,
//     get_Index, get_Size, get_Dimensions, get_Rotation, get_PreferredZoom
//   IPdfPageRenderOptions {3C98056F-B7CF-4C29-9A04-52D90267F425}
//     get/put_SourceRect, get/put_DestinationWidth, get/put_DestinationHeight,
//     get/put_BackgroundColor, get/put_IsIgnoringHighContrast,
//     get/put_BitmapEncoderId
//   IRandomAccessStream  {905A0FE1-BC53-11DF-8C49-001E4FC686DA}
//   IAsyncOperation<T>/IAsyncAction: IInspectable(6) + put_Completed,
//     get_Completed, GetResults
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <roapi.h>
#include <winstring.h>
#include <asyncinfo.h>
#include <shcore.h>
#include <stdint.h>
#include <stddef.h>

#define WISP_PDF_OK 0
#define WISP_PDF_ERR_OS 1
#define WISP_PDF_ERR_INVALID 2
#define WISP_PDF_ERR_PASSWORD 3
#define WISP_PDF_ERR_RENDER 4
#define WISP_PDF_ERR_PAGE_RANGE 5

#define HR_WRONG_PASSWORD ((HRESULT)0x8007052BL)

// ---- dynamic entry points --------------------------------------------------

typedef HRESULT(WINAPI *RoInitializeFn)(RO_INIT_TYPE);
typedef void(WINAPI *RoUninitializeFn)(void);
typedef HRESULT(WINAPI *RoGetActivationFactoryFn)(HSTRING, REFIID, void **);
typedef HRESULT(WINAPI *RoActivateInstanceFn)(HSTRING, IInspectable **);
typedef HRESULT(WINAPI *WindowsCreateStringFn)(PCWSTR, UINT32, HSTRING *);
typedef HRESULT(WINAPI *WindowsDeleteStringFn)(HSTRING);
typedef IStream *(WINAPI *SHCreateMemStreamFn)(const BYTE *, UINT);
typedef HRESULT(WINAPI *CreateRandomAccessStreamOverStreamFn)(IStream *, BSOS_OPTIONS, REFIID, void **);

static RoInitializeFn p_RoInitialize;
static RoUninitializeFn p_RoUninitialize;
static RoGetActivationFactoryFn p_RoGetActivationFactory;
static RoActivateInstanceFn p_RoActivateInstance;
static WindowsCreateStringFn p_WindowsCreateString;
static WindowsDeleteStringFn p_WindowsDeleteString;
static SHCreateMemStreamFn p_SHCreateMemStream;
static CreateRandomAccessStreamOverStreamFn p_CreateRandomAccessStreamOverStream;
static volatile LONG g_entries_state; // 0 = unloaded, 1 = ok, -1 = failed

// Idempotent pointer assignments; concurrent first calls are benign.
static int wisp_load_entries(void) {
    LONG state = g_entries_state;
    if (state != 0) return state == 1;

    HMODULE combase = LoadLibraryW(L"combase.dll");
    HMODULE shlwapi = LoadLibraryW(L"shlwapi.dll");
    HMODULE shcore = LoadLibraryW(L"shcore.dll");
    if (!combase || !shlwapi || !shcore) {
        if (combase) FreeLibrary(combase);
        if (shlwapi) FreeLibrary(shlwapi);
        if (shcore) FreeLibrary(shcore);
        InterlockedExchange(&g_entries_state, -1);
        return 0;
    }
    p_RoInitialize = (RoInitializeFn)(void *)GetProcAddress(combase, "RoInitialize");
    p_RoUninitialize = (RoUninitializeFn)(void *)GetProcAddress(combase, "RoUninitialize");
    p_RoGetActivationFactory = (RoGetActivationFactoryFn)(void *)GetProcAddress(combase, "RoGetActivationFactory");
    p_RoActivateInstance = (RoActivateInstanceFn)(void *)GetProcAddress(combase, "RoActivateInstance");
    p_WindowsCreateString = (WindowsCreateStringFn)(void *)GetProcAddress(combase, "WindowsCreateString");
    p_WindowsDeleteString = (WindowsDeleteStringFn)(void *)GetProcAddress(combase, "WindowsDeleteString");
    p_SHCreateMemStream = (SHCreateMemStreamFn)(void *)GetProcAddress(shlwapi, "SHCreateMemStream");
    p_CreateRandomAccessStreamOverStream =
        (CreateRandomAccessStreamOverStreamFn)(void *)GetProcAddress(shcore, "CreateRandomAccessStreamOverStream");

    int ok = p_RoInitialize && p_RoUninitialize && p_RoGetActivationFactory &&
             p_RoActivateInstance && p_WindowsCreateString && p_WindowsDeleteString &&
             p_SHCreateMemStream && p_CreateRandomAccessStreamOverStream;
    InterlockedExchange(&g_entries_state, ok ? 1 : -1);
    return ok;
}

// ---- IIDs ------------------------------------------------------------------

static const GUID WISP_IID_IPdfDocumentStatics =
    {0x433A0B5F, 0xC007, 0x4788, {0x90, 0xF2, 0x08, 0x14, 0x3D, 0x92, 0x25, 0x99}};
static const GUID WISP_IID_IPdfPageRenderOptions =
    {0x3C98056F, 0xB7CF, 0x4C29, {0x9A, 0x04, 0x52, 0xD9, 0x02, 0x67, 0xF4, 0x25}};
static const GUID WISP_IID_IRandomAccessStream =
    {0x905A0FE1, 0xBC53, 0x11DF, {0x8C, 0x49, 0x00, 0x1E, 0x4F, 0xC6, 0x86, 0xDA}};
static const GUID WISP_IID_IAsyncInfo =
    {0x00000036, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

// ---- minimal WinRT interface declarations ----------------------------------

typedef struct WispPdfDocumentStatics WispPdfDocumentStatics;
typedef struct WispPdfDocument WispPdfDocument;
typedef struct WispPdfPage WispPdfPage;
typedef struct WispPdfPageRenderOptions WispPdfPageRenderOptions;
typedef struct WispAsyncOp WispAsyncOp;     // IAsyncOperation<PdfDocument>
typedef struct WispAsyncAction WispAsyncAction; // IAsyncAction

#define WISP_IINSPECTABLE_SLOTS(T)                                              \
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(T *, REFIID, void **);           \
    ULONG(STDMETHODCALLTYPE *AddRef)(T *);                                      \
    ULONG(STDMETHODCALLTYPE *Release)(T *);                                     \
    HRESULT(STDMETHODCALLTYPE *GetIids)(T *, ULONG *, IID **);                  \
    HRESULT(STDMETHODCALLTYPE *GetRuntimeClassName)(T *, HSTRING *);            \
    HRESULT(STDMETHODCALLTYPE *GetTrustLevel)(T *, int *)

typedef struct WispPdfDocumentStaticsVtbl {
    WISP_IINSPECTABLE_SLOTS(WispPdfDocumentStatics);
    HRESULT(STDMETHODCALLTYPE *LoadFromFileAsync)(WispPdfDocumentStatics *, void *, WispAsyncOp **);
    HRESULT(STDMETHODCALLTYPE *LoadFromFileWithPasswordAsync)(WispPdfDocumentStatics *, void *, HSTRING, WispAsyncOp **);
    HRESULT(STDMETHODCALLTYPE *LoadFromStreamAsync)(WispPdfDocumentStatics *, void *, WispAsyncOp **);
    HRESULT(STDMETHODCALLTYPE *LoadFromStreamWithPasswordAsync)(WispPdfDocumentStatics *, void *, HSTRING, WispAsyncOp **);
} WispPdfDocumentStaticsVtbl;
struct WispPdfDocumentStatics { const WispPdfDocumentStaticsVtbl *lpVtbl; };

typedef struct WispPdfDocumentVtbl {
    WISP_IINSPECTABLE_SLOTS(WispPdfDocument);
    HRESULT(STDMETHODCALLTYPE *GetPage)(WispPdfDocument *, UINT32, WispPdfPage **);
    HRESULT(STDMETHODCALLTYPE *get_PageCount)(WispPdfDocument *, UINT32 *);
    HRESULT(STDMETHODCALLTYPE *get_IsPasswordProtected)(WispPdfDocument *, unsigned char *);
} WispPdfDocumentVtbl;
struct WispPdfDocument { const WispPdfDocumentVtbl *lpVtbl; };

typedef struct WispPdfPageVtbl {
    WISP_IINSPECTABLE_SLOTS(WispPdfPage);
    HRESULT(STDMETHODCALLTYPE *RenderToStreamAsync)(WispPdfPage *, void *, WispAsyncAction **);
    HRESULT(STDMETHODCALLTYPE *RenderWithOptionsToStreamAsync)(WispPdfPage *, void *, WispPdfPageRenderOptions *, WispAsyncAction **);
    HRESULT(STDMETHODCALLTYPE *PreparePageAsync)(WispPdfPage *, WispAsyncAction **);
    HRESULT(STDMETHODCALLTYPE *get_Index)(WispPdfPage *, UINT32 *);
    HRESULT(STDMETHODCALLTYPE *get_Size)(WispPdfPage *, void *);
    HRESULT(STDMETHODCALLTYPE *get_Dimensions)(WispPdfPage *, void **);
    HRESULT(STDMETHODCALLTYPE *get_Rotation)(WispPdfPage *, int *);
    HRESULT(STDMETHODCALLTYPE *get_PreferredZoom)(WispPdfPage *, float *);
} WispPdfPageVtbl;
struct WispPdfPage { const WispPdfPageVtbl *lpVtbl; };

typedef struct WispPdfPageRenderOptionsVtbl {
    WISP_IINSPECTABLE_SLOTS(WispPdfPageRenderOptions);
    HRESULT(STDMETHODCALLTYPE *get_SourceRect)(WispPdfPageRenderOptions *, void *);
    HRESULT(STDMETHODCALLTYPE *put_SourceRect)(WispPdfPageRenderOptions *, void *);
    HRESULT(STDMETHODCALLTYPE *get_DestinationWidth)(WispPdfPageRenderOptions *, UINT32 *);
    HRESULT(STDMETHODCALLTYPE *put_DestinationWidth)(WispPdfPageRenderOptions *, UINT32);
    HRESULT(STDMETHODCALLTYPE *get_DestinationHeight)(WispPdfPageRenderOptions *, UINT32 *);
    HRESULT(STDMETHODCALLTYPE *put_DestinationHeight)(WispPdfPageRenderOptions *, UINT32);
    HRESULT(STDMETHODCALLTYPE *get_BackgroundColor)(WispPdfPageRenderOptions *, void *);
    HRESULT(STDMETHODCALLTYPE *put_BackgroundColor)(WispPdfPageRenderOptions *, void *);
    HRESULT(STDMETHODCALLTYPE *get_IsIgnoringHighContrast)(WispPdfPageRenderOptions *, unsigned char *);
    HRESULT(STDMETHODCALLTYPE *put_IsIgnoringHighContrast)(WispPdfPageRenderOptions *, unsigned char);
    HRESULT(STDMETHODCALLTYPE *get_BitmapEncoderId)(WispPdfPageRenderOptions *, GUID *);
    HRESULT(STDMETHODCALLTYPE *put_BitmapEncoderId)(WispPdfPageRenderOptions *, GUID);
} WispPdfPageRenderOptionsVtbl;
struct WispPdfPageRenderOptions { const WispPdfPageRenderOptionsVtbl *lpVtbl; };

typedef struct WispAsyncOpVtbl {
    WISP_IINSPECTABLE_SLOTS(WispAsyncOp);
    HRESULT(STDMETHODCALLTYPE *put_Completed)(WispAsyncOp *, void *);
    HRESULT(STDMETHODCALLTYPE *get_Completed)(WispAsyncOp *, void **);
    HRESULT(STDMETHODCALLTYPE *GetResults)(WispAsyncOp *, void **);
} WispAsyncOpVtbl;
struct WispAsyncOp { const WispAsyncOpVtbl *lpVtbl; };

typedef struct WispAsyncActionVtbl {
    WISP_IINSPECTABLE_SLOTS(WispAsyncAction);
    HRESULT(STDMETHODCALLTYPE *put_Completed)(WispAsyncAction *, void *);
    HRESULT(STDMETHODCALLTYPE *get_Completed)(WispAsyncAction *, void **);
    HRESULT(STDMETHODCALLTYPE *GetResults)(WispAsyncAction *);
} WispAsyncActionVtbl;
struct WispAsyncAction { const WispAsyncActionVtbl *lpVtbl; };

// ---- helpers ----------------------------------------------------------------

// Poll an async operation/action to completion via IAsyncInfo.
static int wisp_wait_async(IUnknown *op) {
    IAsyncInfo *info = NULL;
    if (FAILED(op->lpVtbl->QueryInterface(op, &WISP_IID_IAsyncInfo, (void **)&info)) || !info)
        return WISP_PDF_ERR_OS;
    for (;;) {
        AsyncStatus st = Started;
        if (FAILED(info->lpVtbl->get_Status(info, &st))) {
            info->lpVtbl->Release(info);
            return WISP_PDF_ERR_OS;
        }
        if (st == Completed) {
            info->lpVtbl->Release(info);
            return WISP_PDF_OK;
        }
        if (st != Started) { // Canceled or Error
            HRESULT code = E_FAIL;
            info->lpVtbl->get_ErrorCode(info, &code);
            info->lpVtbl->Release(info);
            return code == HR_WRONG_PASSWORD ? WISP_PDF_ERR_PASSWORD : WISP_PDF_ERR_INVALID;
        }
        Sleep(2);
    }
}

// Drain the backing IStream (already positioned at an arbitrary point) into a
// HeapAlloc buffer. Returns WISP_PDF_OK and transfers ownership on success.
static int wisp_read_stream(IStream *stream, unsigned char **out, size_t *out_len) {
    STATSTG stat;
    if (FAILED(stream->lpVtbl->Stat(stream, &stat, STATFLAG_NONAME))) return WISP_PDF_ERR_OS;
    ULONGLONG size64 = stat.cbSize.QuadPart;
    if (size64 == 0 || size64 > 256ull * 1024 * 1024) return WISP_PDF_ERR_RENDER;
    SIZE_T size = (SIZE_T)size64;

    LARGE_INTEGER zero = {0};
    if (FAILED(stream->lpVtbl->Seek(stream, zero, STREAM_SEEK_SET, NULL))) return WISP_PDF_ERR_OS;

    unsigned char *buf = (unsigned char *)HeapAlloc(GetProcessHeap(), 0, size);
    if (!buf) return WISP_PDF_ERR_OS;
    SIZE_T got = 0;
    while (got < size) {
        ULONG chunk = 0;
        HRESULT hr = stream->lpVtbl->Read(stream, buf + got, (ULONG)(size - got), &chunk);
        if (FAILED(hr) || chunk == 0) {
            HeapFree(GetProcessHeap(), 0, buf);
            return WISP_PDF_ERR_OS;
        }
        got += chunk;
    }
    *out = buf;
    *out_len = size;
    return WISP_PDF_OK;
}

// ---- public entry points -----------------------------------------------------

void wisp_pdf_free(void *p) {
    if (p) HeapFree(GetProcessHeap(), 0, p);
}

// Renders one 0-based page of an in-memory PDF to PNG bytes at target_width
// pixels wide (aspect preserved). *out_png is HeapAlloc'd; release with
// wisp_pdf_free. Returns a WISP_PDF_* code.
int wisp_pdf_render_page(const unsigned char *pdf, size_t pdf_len,
                         unsigned int page_index, unsigned int target_width,
                         unsigned char **out_png, size_t *out_png_len,
                         unsigned int *out_page_count) {
    *out_png = NULL;
    *out_png_len = 0;
    *out_page_count = 0;
    if (!pdf || pdf_len == 0 || pdf_len > 0xFFFFFFFFu || target_width == 0)
        return WISP_PDF_ERR_INVALID;
    if (!wisp_load_entries()) return WISP_PDF_ERR_OS;

    HRESULT init_hr = p_RoInitialize(RO_INIT_MULTITHREADED);
    int owe_uninit = init_hr == S_OK || init_hr == S_FALSE;
    if (FAILED(init_hr) && init_hr != RPC_E_CHANGED_MODE) return WISP_PDF_ERR_OS;

    int rc = WISP_PDF_ERR_OS;
    HSTRING cls_doc = NULL, cls_opts = NULL;
    WispPdfDocumentStatics *statics = NULL;
    IStream *in_stream = NULL;
    void *in_ras = NULL;
    WispAsyncOp *load_op = NULL;
    WispPdfDocument *doc = NULL;
    WispPdfPage *page = NULL;
    IInspectable *opts_insp = NULL;
    WispPdfPageRenderOptions *opts = NULL;
    IStream *out_stream = NULL;
    void *out_ras = NULL;
    WispAsyncAction *render_op = NULL;

    static const WCHAR doc_class[] = L"Windows.Data.Pdf.PdfDocument";
    static const WCHAR opts_class[] = L"Windows.Data.Pdf.PdfPageRenderOptions";
    if (FAILED(p_WindowsCreateString(doc_class, (UINT32)(sizeof(doc_class) / sizeof(WCHAR) - 1), &cls_doc))) goto done;
    if (FAILED(p_RoGetActivationFactory(cls_doc, &WISP_IID_IPdfDocumentStatics, (void **)&statics))) goto done;

    in_stream = p_SHCreateMemStream(pdf, (UINT)pdf_len);
    if (!in_stream) goto done;
    if (FAILED(p_CreateRandomAccessStreamOverStream(in_stream, BSOS_DEFAULT, &WISP_IID_IRandomAccessStream, &in_ras))) goto done;

    if (FAILED(statics->lpVtbl->LoadFromStreamAsync(statics, in_ras, &load_op))) goto done;
    rc = wisp_wait_async((IUnknown *)load_op);
    if (rc != WISP_PDF_OK) goto done;
    rc = WISP_PDF_ERR_OS;
    if (FAILED(load_op->lpVtbl->GetResults(load_op, (void **)&doc)) || !doc) {
        rc = WISP_PDF_ERR_INVALID;
        goto done;
    }

    unsigned char locked = 0;
    if (SUCCEEDED(doc->lpVtbl->get_IsPasswordProtected(doc, &locked)) && locked) {
        rc = WISP_PDF_ERR_PASSWORD;
        goto done;
    }
    UINT32 page_count = 0;
    if (FAILED(doc->lpVtbl->get_PageCount(doc, &page_count))) goto done;
    *out_page_count = page_count;
    if (page_index >= page_count) {
        rc = WISP_PDF_ERR_PAGE_RANGE;
        goto done;
    }
    if (FAILED(doc->lpVtbl->GetPage(doc, page_index, &page)) || !page) goto done;

    if (FAILED(p_WindowsCreateString(opts_class, (UINT32)(sizeof(opts_class) / sizeof(WCHAR) - 1), &cls_opts))) goto done;
    if (FAILED(p_RoActivateInstance(cls_opts, &opts_insp)) || !opts_insp) goto done;
    if (FAILED(opts_insp->lpVtbl->QueryInterface(opts_insp, &WISP_IID_IPdfPageRenderOptions, (void **)&opts))) goto done;
    if (FAILED(opts->lpVtbl->put_DestinationWidth(opts, target_width))) goto done;

    out_stream = p_SHCreateMemStream(NULL, 0);
    if (!out_stream) goto done;
    if (FAILED(p_CreateRandomAccessStreamOverStream(out_stream, BSOS_DEFAULT, &WISP_IID_IRandomAccessStream, &out_ras))) goto done;

    if (FAILED(page->lpVtbl->RenderWithOptionsToStreamAsync(page, out_ras, opts, &render_op))) goto done;
    rc = wisp_wait_async((IUnknown *)render_op);
    if (rc != WISP_PDF_OK) {
        if (rc == WISP_PDF_ERR_INVALID) rc = WISP_PDF_ERR_RENDER;
        goto done;
    }
    if (FAILED(render_op->lpVtbl->GetResults(render_op))) {
        rc = WISP_PDF_ERR_RENDER;
        goto done;
    }

    rc = wisp_read_stream(out_stream, out_png, out_png_len);

done:
    if (render_op) render_op->lpVtbl->Release(render_op);
    if (out_ras) ((IUnknown *)out_ras)->lpVtbl->Release((IUnknown *)out_ras);
    if (out_stream) out_stream->lpVtbl->Release(out_stream);
    if (opts) opts->lpVtbl->Release(opts);
    if (opts_insp) opts_insp->lpVtbl->Release(opts_insp);
    if (page) page->lpVtbl->Release(page);
    if (doc) doc->lpVtbl->Release(doc);
    if (load_op) load_op->lpVtbl->Release(load_op);
    if (in_ras) ((IUnknown *)in_ras)->lpVtbl->Release((IUnknown *)in_ras);
    if (in_stream) in_stream->lpVtbl->Release(in_stream);
    if (statics) statics->lpVtbl->Release(statics);
    if (cls_opts) p_WindowsDeleteString(cls_opts);
    if (cls_doc) p_WindowsDeleteString(cls_doc);
    if (owe_uninit) p_RoUninitialize();
    return rc;
}
