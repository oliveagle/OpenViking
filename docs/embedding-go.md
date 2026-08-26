# Embedding OpenViking storage into Go (cgo)

This guide covers embedding the OpenViking `ragfs` local filesystem into a Go
program (CLI, daemon, server) via the `crates/ragfs-ffi` C shim and cgo. This
is the approach taken by `devine_cli` (`internal/vikingfs` + `port.VikingClient`).

## What you get

- A **static library** (`libragfs_ffi.a` / `ragfs_ffi.lib`) that owns the whole
  ragfs engine, exposed through a tiny, stable C ABI.
- A **C header** (`ragfs_ffi.h`) — cgo `import "C"` consumes both.
- No Python wheel, no subprocess, no network at runtime: the filesystem is
  fully in-process.

## ABI overview

| Go call                | C symbol              | Notes |
| ---                    | ---                   | ---   |
| open                   | `viking_fs_open`      | opaque handle; base path must exist |
| close                  | `viking_fs_close`     | exactly once per open |
| read file              | `viking_fs_get`       | returns malloc'd bytes + `*out_len` |
| write file             | `viking_fs_put`       | auto-creates parents, create-or-truncate |
| mkdir                  | `viking_fs_mkdir`     | existing dir is success |
| delete                 | `viking_fs_delete`    | |
| list dir               | `viking_fs_list`      | JSON `[{"name","size","is_dir"}]` |
| last error             | `viking_last_error`   | thread-local; same thread only |
| free buffer            | `viking_free`         | for anything `viking_fs_*` returned |

The staticlib keeps the file name `libragfs_ffi.a` for compatibility with the
release archives; only the exported symbol prefix is `viking_*` (canonical
OpenViking naming, matching `devine_cli`'s `vikingfs_*` convention).

## Obtaining the library

### A. From a release archive (recommended)

`.github/workflows/release-binaries.yml` ships the CLI and the lib on two
independent release tracks — tag `v<version>` releases both, tag
`lib@<version>` releases **lib only** (the track Go embedders want), tag
`cli@<version>` releases CLI only, and `workflow_dispatch` accepts a
`component` input (`all` / `cli` / `lib`). Per platform the archives are:

```
openviking-<version>-<platform>-cli.{tar.gz,zip}   # the ov CLI binary
openviking-<version>-<platform>-lib.{tar.gz,zip}   # the staticlib + header
```

The `-lib` archive contains:

```
lib/libragfs_ffi.a    # ragfs_ffi.lib on Windows
include/ragfs_ffi.h
```

Embedding into Go only needs the `-lib` archive. Extract the one matching
your **build machine** (the Go binary's target arch/OS must match the
staticlib's), then in your `.go` file:

```go
//go:build cgo

/*
#cgo CFLAGS:  -I<extracted>/include
#cgo LDFLAGS: -L<extracted>/lib -lragfs_ffi -lpthread -lm
#cgo linux  LDFLAGS: -lresolv
#cgo darwin LDFLAGS: -framework Security -framework CoreFoundation -framework SystemConfiguration

#include <stdlib.h>
#include <stdint.h>
#include <ragfs_ffi.h>
*/
import "C"
```

### B. Build from source

```sh
cargo build --release -p ragfs-ffi   # from the OpenViking repo root
```

Artifacts land in `target/release/`:
`libragfs_ffi.a` (unix) / `ragfs_ffi.lib` (Windows MSVC), header at
`crates/ragfs-ffi/include/ragfs_ffi.h`.

## Minimal wrapper

A production wrapper looks like `devine_cli/internal/vikingfs` and the
reference at `examples/ragfs_go/main.go`. Key points:

```go
type FsHandle struct{ ptr unsafe.Pointer }

func Open(base string) (*FsHandle, error) {
    // base MUST exist first (os.MkdirAll)
    cBase := C.CString(base); defer C.free(unsafe.Pointer(cBase))
    h := C.viking_fs_open(cBase)
    if h == nil { return nil, fmt.Errorf("open: %s", lastError()) }
    return &FsHandle{ptr: h}, nil
}

func (h *FsHandle) Get(path string) ([]byte, error) {
    cPath := C.CString(path); defer C.free(unsafe.Pointer(cPath))
    var n C.uint64_t
    buf := C.viking_fs_get(h.ptr, cPath, &n)
    if buf == nil { return nil, fmt.Errorf("get %s: %s", path, lastError()) }
    defer C.viking_free(buf)                 // must free!
    return C.GoBytes(buf, C.int(n)), nil
}

func lastError() string {
    if m := C.viking_last_error(); m != nil { return C.GoString(m) }
    return "unknown error"
}
```

## Rules that will save you

1. **Base path must exist** before `viking_fs_open`.
2. **Always `viking_free`** buffers from `viking_fs_get` / `viking_fs_list`.
3. **`viking_last_error` is thread-local** — read it immediately on the same
   goroutine, before the next `viking_*` call.
4. **Free C strings** made with `C.CString` via `C.free`.
5. **Match the staticlib's platform**: a Linux amd64 Go build needs the
   `linux-amd64` archive; cross-Go-compiling requires a C cross-toolchain
   (zig cc). `CGO_ENABLED=0` is not an option when embedding ragfs.
6. **Thread-safety**: one `viking_fs_open` handle is not meant to be used
   concurrently from many goroutines; serialize access or open per worker.

## Reference implementation

- `crates/ragfs-ffi/` — the shim crate (`Cargo.toml`, `src/lib.rs`).
- `crates/ragfs-ffi/include/ragfs_ffi.h` — the C header.
- `examples/ragfs_go/` — a complete, runnable Go example.
- `devine_cli/internal/vikingfs` — production cgo wrapper.
- `devine_cli/internal/domain/port/viking_client.go` — the `port.VikingClient`
  interface (Sync / List / Read / Search / Write / Remove) that decouples
  business logic from the cgo layer.
