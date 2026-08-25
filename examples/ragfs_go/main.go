// Command ragfs_go demonstrates embedding ragfs into a Go program via cgo.
//
// It links against the ragfs-ffi staticlib produced by:
//
//	cd crates/ragfs-ffi && cargo build --release
//
// The archive lands at target/release/libragfs_ffi.a (unix) or
// target/release/ragfs_ffi.lib (Windows MSVC), together with the C header
// at crates/ragfs-ffi/include/ragfs_ffi.h.
//
// Run:
//
//	# from the repo root (unix)
//	cargo build --release -p ragfs-ffi
//	go run ./examples/ragfs_go
//
// The example exercises the full viking_fs_* ABI: open, put, list, get,
// mkdir, delete, close.
package main

/*
#cgo CFLAGS: -I${SRCDIR}/../../crates/ragfs-ffi/include
#cgo LDFLAGS: -L${SRCDIR}/../../target/release -lragfs_ffi -lpthread -lm
#cgo linux LDFLAGS: -lresolv
#cgo darwin LDFLAGS: -framework Security -framework CoreFoundation -framework SystemConfiguration

#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <ragfs_ffi.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"unsafe"
)

// FsHandle is an opaque wrapper around the C handle returned by viking_fs_open.
type FsHandle struct{ ptr unsafe.Pointer }

// Open creates a ragfs LocalFileSystem rooted at basePath.
func Open(basePath string) (*FsHandle, error) {
	cPath := C.CString(basePath)
	defer C.free(unsafe.Pointer(cPath))

	h := C.viking_fs_open(cPath)
	if h == nil {
		return nil, fmt.Errorf("ragfs open %q: %s", basePath, lastError())
	}
	return &FsHandle{ptr: h}, nil
}

// Close releases the underlying filesystem handle.
func (h *FsHandle) Close() {
	if h.ptr != nil {
		C.viking_fs_close(h.ptr)
		h.ptr = nil
	}
}

// Put writes data to path, auto-creating parent directories.
func (h *FsHandle) Put(path string, data []byte) error {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	var p unsafe.Pointer
	if len(data) > 0 {
		p = unsafe.Pointer(&data[0])
	}
	rc := C.viking_fs_put(h.ptr, cPath, p, C.size_t(len(data)))
	if rc != 0 {
		return fmt.Errorf("ragfs put %q: %s", path, lastError())
	}
	return nil
}

// Get reads the file at path. A missing file returns (nil, nil).
func (h *FsHandle) Get(path string) ([]byte, error) {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	var outLen C.uint64_t
	buf := C.viking_fs_get(h.ptr, cPath, &outLen)
	if buf == nil {
		if outLen == 0 {
			return nil, nil // empty or missing file
		}
		return nil, fmt.Errorf("ragfs get %q: %s", path, lastError())
	}
	defer C.viking_free(buf)
	return C.GoBytes(buf, C.int(outLen)), nil
}

// Mkdir creates a single directory; an existing directory is not an error.
func (h *FsHandle) Mkdir(path string) error {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	if rc := C.viking_fs_mkdir(h.ptr, cPath, C.int(0o755)); rc != 0 {
		return fmt.Errorf("ragfs mkdir %q: %s", path, lastError())
	}
	return nil
}

// Delete removes the file at path.
func (h *FsHandle) Delete(path string) error {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	if rc := C.viking_fs_delete(h.ptr, cPath); rc != 0 {
		return fmt.Errorf("ragfs delete %q: %s", path, lastError())
	}
	return nil
}

// DirEntry mirrors the {"name","size","is_dir"} JSON emitted by viking_fs_list.
type DirEntry struct {
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	IsDir bool   `json:"is_dir"`
}

// List returns the entries of a directory.
func (h *FsHandle) List(path string) ([]DirEntry, error) {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	buf := C.viking_fs_list(h.ptr, cPath)
	if buf == nil {
		return nil, fmt.Errorf("ragfs list %q: %s", path, lastError())
	}
	defer C.viking_free(unsafe.Pointer(buf))

	var entries []DirEntry
	if err := json.Unmarshal([]byte(C.GoString(buf)), &entries); err != nil {
		return nil, fmt.Errorf("ragfs list %q: parse entries: %w", path, err)
	}
	return entries, nil
}

func lastError() string {
	if msg := C.viking_last_error(); msg != nil {
		return C.GoString(msg)
	}
	return "unknown error"
}

func main() {
	root, err := os.MkdirTemp("", "ragfs-go-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "mkdtemp:", err)
		os.Exit(1)
	}
	defer os.RemoveAll(root)
	base := filepath.Join(root, "store")
	// ragfs LocalFileSystem requires the base path to already exist.
	if err := os.MkdirAll(base, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "mkdir:", err)
		os.Exit(1)
	}

	fs, err := Open(base)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer fs.Close()

	// write + read back
	hello := []byte("hello from ragfs via cgo")
	if err := fs.Put("docs/notes.txt", hello); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	got, err := fs.Get("docs/notes.txt")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("get  docs/notes.txt -> %q\n", got)

	// list top-level
	entries, err := fs.List("")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	for _, e := range entries {
		fmt.Printf("list %-10s size=%-4d dir=%v\n", e.Name, e.Size, e.IsDir)
	}

	// mkdir is idempotent
	if err := fs.Mkdir("docs"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	// delete
	if err := fs.Delete("docs/notes.txt"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if gone, _ := fs.Get("docs/notes.txt"); gone == nil {
		fmt.Println("delete docs/notes.txt -> gone")
	}

	_ = hello
	fmt.Println("ok")
}
