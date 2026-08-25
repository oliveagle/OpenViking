//! ragfs_ffi — C FFI shim over ragfs (LocalFileSystem) for embedding ragfs into
//! C / Go (via cgo) / other languages.
//!
//! This crate is the canonical, reusable counterpart of the shim that lives
//! inside devine_cli (`internal/vikingfs/ffi`). It wraps `ragfs::plugins::localfs::LocalFileSystem`
//! behind a synchronous tokio runtime and exposes a small, stable C ABI
//! (`viking_fs_*` + `viking_last_error` + `viking_free`).
//!
//! The produced staticlib (`libragfs_ffi.a` on unix, `ragfs_ffi.lib` on MSVC)
//! plus the cbindgen-generated header (`include/ragfs_ffi.h`) let any Go program
//! embed ragfs directly, without depending on the OpenViking Python wheel.
//!
//! Basic usage from Go:
//! ```go
//! // #cgo LDFLAGS: -L${SRCDIR} -lragfs_ffi
//! // #cgo CFLAGS: -I${SRCDIR}
//! // #include <ragfs_ffi.h>
//! // #include <stdlib.h>
//! import "C"
//! ```

use std::ffi::{CStr, CString, c_char, c_int, c_void};

use ragfs::core::{FileSystem, Result as RagfsResult, WriteFlag};
use ragfs::plugins::localfs::LocalFileSystem;

/// Opaque handle to a ragfs filesystem + its owning tokio runtime.
pub struct FsHandle {
    runtime: tokio::runtime::Runtime,
    fs: Box<dyn FileSystem>,
}

impl FsHandle {
    fn new(base_path: &str) -> Result<Self, String> {
        let runtime = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
        let local = LocalFileSystem::new(base_path).map_err(|e| e.to_string())?;
        let fs: Box<dyn FileSystem> = Box::new(local);
        Ok(FsHandle { runtime, fs })
    }

    fn block<F, T>(&self, f: F) -> T
    where
        F: FnOnce(&dyn FileSystem) -> std::pin::Pin<
            Box<dyn std::future::Future<Output = T> + Send + '_>,
        >,
    {
        self.runtime.block_on(f(self.fs.as_ref()))
    }
}

fn err_string<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

// ---------------------------------------------------------------------------
// C-string / byte-buffer marshalling helpers
// ---------------------------------------------------------------------------

/// Copy a Rust String into a malloc-allocated C string; caller must `viking_free`.
unsafe fn to_c_string(s: String) -> *mut c_char {
    let c = CString::new(s).unwrap_or_else(|_| CString::new("").unwrap());
    c.into_raw()
}

/// Copy raw bytes into a malloc-allocated buffer; caller must `viking_free`.
unsafe fn to_c_bytes(data: Vec<u8>) -> *mut c_void {
    let len = data.len();
    if len == 0 {
        return std::ptr::null_mut();
    }
    let layout = std::alloc::Layout::from_size_align_unchecked(len, 1);
    let ptr = std::alloc::alloc(layout) as *mut u8;
    std::ptr::copy_nonoverlapping(data.as_ptr(), ptr, len);
    ptr as *mut c_void
}

unsafe fn c_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok()
}

unsafe fn c_bytes<'a>(ptr: *const c_void, len: usize) -> Option<&'a [u8]> {
    if ptr.is_null() && len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    Some(std::slice::from_raw_parts(ptr as *const u8, len))
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

/// Open a ragfs `LocalFileSystem` rooted at `base_path`. Returns an opaque
/// handle, or null on error (check `viking_last_error`).
///
/// # Safety
/// `base_path` must be a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn viking_fs_open(base_path: *const c_char) -> *mut c_void {
    let Some(path) = c_str(base_path) else {
        set_last_error("viking_fs_open: null path");
        return std::ptr::null_mut();
    };
    match FsHandle::new(path) {
        Ok(h) => Box::into_raw(Box::new(h)) as *mut c_void,
        Err(e) => {
            set_last_error(&e);
            std::ptr::null_mut()
        }
    }
}

/// Close and free a handle returned by `viking_fs_open`.
///
/// # Safety
/// `handle` must come from `viking_fs_open` and be used at most once.
#[no_mangle]
pub unsafe extern "C" fn viking_fs_close(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    drop(Box::from_raw(handle as *mut FsHandle));
}

/// Read a file's contents. Returns a malloc-allocated byte buffer (or null for
/// an empty/missing file); `out_len` receives the byte count.
///
/// # Safety
/// `handle` valid; `path` NUL-terminated; `out_len` non-null writable u64.
#[no_mangle]
pub unsafe extern "C" fn viking_fs_get(
    handle: *mut c_void,
    path: *const c_char,
    out_len: *mut u64,
) -> *mut c_void {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    *out_len = 0;
    if handle.is_null() {
        set_last_error("viking_fs_get: null handle");
        return std::ptr::null_mut();
    }
    let Some(path) = c_str(path) else {
        set_last_error("viking_fs_get: null path");
        return std::ptr::null_mut();
    };
    let h = &*(handle as *const FsHandle);
    match h.block(|fs| Box::pin(async move { fs.read(path, 0, 0).await })) {
        Ok(data) => {
            *out_len = data.len() as u64;
            to_c_bytes(data)
        }
        Err(e) => {
            set_last_error(&err_string(e));
            std::ptr::null_mut()
        }
    }
}

/// Write a file's contents. Auto-creates parent directories.
/// Returns 0 on success, non-zero on error.
///
/// # Safety
/// `handle` valid; `path` NUL-terminated; `data`/`len` valid byte buffer.
#[no_mangle]
pub unsafe extern "C" fn viking_fs_put(
    handle: *mut c_void,
    path: *const c_char,
    data: *const c_void,
    len: usize,
) -> c_int {
    if handle.is_null() {
        set_last_error("viking_fs_put: null handle");
        return -1;
    }
    let Some(path) = c_str(path) else {
        set_last_error("viking_fs_put: null path");
        return -1;
    };
    let Some(data) = c_bytes(data, len) else {
        set_last_error("viking_fs_put: null data");
        return -1;
    };
    let path = path.to_string();
    let data = data.to_vec();
    let h = &*(handle as *const FsHandle);
    match h.block(|fs| {
        let path = path.clone();
        let data = data.clone();
        Box::pin(async move {
            // Auto-create parent directories.
            let flag = WriteFlag::Create; // Create-or-truncate (POSIX O_CREAT semantics)
            let mut prefixes: Vec<String> = Vec::new();
            let mut acc = String::new();
            for part in path.split('/') {
                if part.is_empty() {
                    continue;
                }
                if !acc.is_empty() {
                    acc.push('/');
                }
                acc.push_str(part);
                prefixes.push(acc.clone());
            }
            if prefixes.len() > 1 {
                prefixes.pop();
            }
            for p in &prefixes {
                let _ = fs.mkdir(p, 0o755).await;
            }
            fs.write(&path, &data, 0, flag).await
        })
    }) {
        Ok(_) => 0,
        Err(e) => {
            set_last_error(&err_string(e));
            -1
        }
    }
}

/// Create a single directory. Returns 0 on success (including if the directory
/// already exists), non-zero on other errors.
///
/// # Safety
/// `handle` non-null; `path` NUL-terminated; `mode` is a Unix permission mode.
#[no_mangle]
pub unsafe extern "C" fn viking_fs_mkdir(
    handle: *mut c_void,
    path: *const c_char,
    mode: c_int,
) -> c_int {
    let Some(handle) = (if handle.is_null() { None } else { Some(&*(handle as *const FsHandle)) }) else {
        set_last_error("viking_fs_mkdir: null handle");
        return -1;
    };
    let Some(path) = c_str(path) else {
        set_last_error("viking_fs_mkdir: null path");
        return -1;
    };
    let path = path.to_string();
    match handle.block(|h| Box::pin(async move { h.mkdir(&path, mode as u32).await })) {
        Ok(_) => 0,
        Err(e) => {
            let s = err_string(e);
            if s.contains("already exists") || s.contains("AlreadyExists") {
                return 0;
            }
            set_last_error(&s);
            -1
        }
    }
}

/// Delete a file. Returns 0 on success, non-zero on error.
///
/// # Safety
/// `handle` non-null; `path` NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn viking_fs_delete(handle: *mut c_void, path: *const c_char) -> c_int {
    let Some(handle) = (if handle.is_null() { None } else { Some(&*(handle as *const FsHandle)) }) else {
        set_last_error("viking_fs_delete: null handle");
        return -1;
    };
    let Some(path) = c_str(path) else {
        set_last_error("viking_fs_delete: null path");
        return -1;
    };
    let path = path.to_string();
    match handle.block(|h| Box::pin(async move { h.remove(&path).await })) {
        Ok(_) => 0,
        Err(e) => {
            set_last_error(&err_string(e));
            -1
        }
    }
}

/// List a directory. Returns a malloc-allocated UTF-8 JSON array of
/// `{"name","size","is_dir"}`, or null on error.
///
/// # Safety
/// `handle` non-null; `path` NUL-terminated.
#[no_mangle]
pub unsafe extern "C" fn viking_fs_list(handle: *mut c_void, path: *const c_char) -> *mut c_char {
    let Some(handle) = (if handle.is_null() { None } else { Some(&*(handle as *const FsHandle)) }) else {
        set_last_error("viking_fs_list: null handle");
        return std::ptr::null_mut();
    };
    let Some(path) = c_str(path) else {
        set_last_error("viking_fs_list: null path");
        return std::ptr::null_mut();
    };
    let path = path.to_string();
    let result: RagfsResult<Vec<serde_json::Value>> = handle.block(move |h| {
        let path = path.clone();
        Box::pin(async move {
            let entries = h.read_dir(&path).await?;
            Ok(entries
                .iter()
                .map(|e| {
                    serde_json::json!({
                        "name": e.name,
                        "size": e.size,
                        "is_dir": e.is_dir,
                    })
                })
                .collect())
        })
    });
    match result {
        Ok(entries) => {
            let s = serde_json::to_string(&entries).unwrap_or_else(|_| "[]".to_string());
            to_c_string(s)
        }
        Err(e) => {
            set_last_error(&err_string(e));
            std::ptr::null_mut()
        }
    }
}

thread_local! {
    static LAST_ERR: std::cell::RefCell<CString> = std::cell::RefCell::new(CString::default());
}

fn set_last_error(msg: &str) {
    LAST_ERR.with(|b| {
        *b.borrow_mut() = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    });
}

/// Get the most recent error message (thread-local). Returns a C string that is
/// valid until the next `viking_*` call on this thread.
#[no_mangle]
pub extern "C" fn viking_last_error() -> *const c_char {
    LAST_ERR.with(|b| b.borrow().as_ptr())
}

/// Free a buffer previously returned by `viking_fs_*`.
///
/// # Safety
/// `ptr` must have been returned by this crate's allocators.
#[no_mangle]
pub unsafe extern "C" fn viking_free(ptr: *mut c_void) {
    if ptr.is_null() {
        return;
    }
    libc::free(ptr);
}
