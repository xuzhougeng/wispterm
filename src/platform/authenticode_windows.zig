//! WinVerifyTrust (WINTRUST_ACTION_GENERIC_VERIFY_V2) plus the signer
//! certificate's subject, read from the verified state data with
//! WTHelperProvDataFromStateData / WTHelperGetProvSignerFromChain.
//!
//! Revocation is not checked online: an update can be staged on a machine
//! with no route to the CA's CRL server, and the file's SHA-256 already
//! matched the release's published digest.
const std = @import("std");
const windows = std.os.windows;
const authenticode = @import("authenticode.zig");

const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const HANDLE = windows.HANDLE;
const HWND = windows.HWND;
const GUID = windows.GUID;
const LONG = windows.LONG;

const WINTRUST_FILE_INFO = extern struct {
    cbStruct: DWORD,
    pcwszFilePath: [*:0]const u16,
    hFile: ?HANDLE,
    pgKnownSubject: ?*const GUID,
};

const WINTRUST_DATA = extern struct {
    cbStruct: DWORD,
    pPolicyCallbackData: ?*anyopaque,
    pSIPClientData: ?*anyopaque,
    dwUIChoice: DWORD,
    fdwRevocationChecks: DWORD,
    dwUnionChoice: DWORD,
    pFile: *WINTRUST_FILE_INFO,
    dwStateAction: DWORD,
    hWVTStateData: ?HANDLE,
    pwszURLReference: ?[*:0]u16,
    dwProvFlags: DWORD,
    dwUIContext: DWORD,
    pSignatureSettings: ?*anyopaque,
};

const FILETIME = extern struct { dwLowDateTime: DWORD, dwHighDateTime: DWORD };

/// Leading fields of CRYPT_PROVIDER_CERT; only element 0 is read through it.
const CRYPT_PROVIDER_CERT = extern struct {
    cbStruct: DWORD,
    pCert: ?*const anyopaque, // PCCERT_CONTEXT
};

/// Leading fields of CRYPT_PROVIDER_SGNR, up to the certificate chain.
const CRYPT_PROVIDER_SGNR = extern struct {
    cbStruct: DWORD,
    sftVerifyAsOf: FILETIME,
    csCertChain: DWORD,
    pasCertChain: ?[*]CRYPT_PROVIDER_CERT,
};

const WTD_UI_NONE: DWORD = 2;
const WTD_REVOKE_NONE: DWORD = 0;
const WTD_CHOICE_FILE: DWORD = 1;
const WTD_STATEACTION_VERIFY: DWORD = 1;
const WTD_STATEACTION_CLOSE: DWORD = 2;
const WTD_REVOCATION_CHECK_NONE: DWORD = 0x10;
const WTD_CACHE_ONLY_URL_RETRIEVAL: DWORD = 0x1000;
const CERT_NAME_SIMPLE_DISPLAY_TYPE: DWORD = 4;

const WINTRUST_ACTION_GENERIC_VERIFY_V2 = GUID{
    .Data1 = 0x00aac56b,
    .Data2 = 0xcd44,
    .Data3 = 0x11d0,
    .Data4 = .{ 0x8c, 0xc2, 0x00, 0xc0, 0x4f, 0xc2, 0x95, 0xee },
};

extern "wintrust" fn WinVerifyTrust(hwnd: ?HWND, pgActionID: *const GUID, pWVTData: *anyopaque) callconv(.winapi) LONG;
extern "wintrust" fn WTHelperProvDataFromStateData(hStateData: HANDLE) callconv(.winapi) ?*anyopaque;
extern "wintrust" fn WTHelperGetProvSignerFromChain(
    pProvData: *anyopaque,
    idxSigner: DWORD,
    fCounterSigner: BOOL,
    idxCounterSigner: DWORD,
) callconv(.winapi) ?*CRYPT_PROVIDER_SGNR;
extern "crypt32" fn CertGetNameStringW(
    pCertContext: *const anyopaque,
    dwType: DWORD,
    dwFlags: DWORD,
    pvTypePara: ?*anyopaque,
    pszNameString: ?[*]u16,
    cchNameString: DWORD,
) callconv(.winapi) DWORD;

pub fn signerSubject(path: []const u8, buf: *[authenticode.subject_buffer_len]u8) ?[]const u8 {
    var path_buf: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(&path_buf, path) catch return null;
    if (len >= path_buf.len) return null;
    path_buf[len] = 0;

    var file_info = WINTRUST_FILE_INFO{
        .cbStruct = @sizeOf(WINTRUST_FILE_INFO),
        .pcwszFilePath = path_buf[0..len :0],
        .hFile = null,
        .pgKnownSubject = null,
    };
    var data = WINTRUST_DATA{
        .cbStruct = @sizeOf(WINTRUST_DATA),
        .pPolicyCallbackData = null,
        .pSIPClientData = null,
        .dwUIChoice = WTD_UI_NONE,
        .fdwRevocationChecks = WTD_REVOKE_NONE,
        .dwUnionChoice = WTD_CHOICE_FILE,
        .pFile = &file_info,
        .dwStateAction = WTD_STATEACTION_VERIFY,
        .hWVTStateData = null,
        .pwszURLReference = null,
        .dwProvFlags = WTD_REVOCATION_CHECK_NONE | WTD_CACHE_ONLY_URL_RETRIEVAL,
        .dwUIContext = 0,
        .pSignatureSettings = null,
    };
    const action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    const status = WinVerifyTrust(null, &action, &data);
    defer {
        data.dwStateAction = WTD_STATEACTION_CLOSE;
        _ = WinVerifyTrust(null, &action, &data);
    }
    if (status != 0) return null;

    const state = data.hWVTStateData orelse return null;
    const prov = WTHelperProvDataFromStateData(state) orelse return null;
    const signer = WTHelperGetProvSignerFromChain(prov, 0, windows.FALSE, 0) orelse return null;
    if (signer.csCertChain == 0) return null;
    const chain = signer.pasCertChain orelse return null;
    const cert = chain[0].pCert orelse return null;

    var wide: [authenticode.subject_buffer_len]u16 = undefined;
    const n = CertGetNameStringW(cert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, null, &wide, wide.len);
    // n counts the terminating NUL; 1 means an empty name.
    if (n <= 1) return null;
    const name = wide[0..@min(n - 1, wide.len)];
    if (std.unicode.calcWtf8Len(name) > buf.len) return null;
    const utf8_len = std.unicode.wtf16LeToWtf8(buf, name);
    return buf[0..utf8_len];
}
