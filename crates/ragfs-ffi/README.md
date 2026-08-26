# ragfs-ffi

C FFI shim over [ragfs](https://github.com/oliveagle/OpenViking/tree/main/crates/ragfs)
(`LocalFileSystem`) for embedding ragfs into C / **Go (via cgo)** / other languages.

This is the reusable, upstream counterpart of the shim used by `devine_cli`
(`internal/vikingfs/ffi`). The released staticlib (`libragfs_ffi.a` on unix,
`ragfs_ffi.lib` on MSVC) plus the C header let any Go program embed ragfs
directly — no Python wheel required.

## What is released

The CLI and the lib ship on independent release tracks
(`.github/workflows/release-binaries.yml`): tag `v<version>` releases both,
tag `lib@<version>` releases the **lib only** (the track Go embedders want).
Per platform the archives are `openviking-<version>-<platform>-{cli,lib}.{tar.gz,zip}`:

```
-cli:  ov                       # the OpenViking CLI binary (or ov.exe on Windows)
-lib:  lib/libragfs_ffi.a       # the staticlib (or lib/ragfs_ffi.lib on Windows)
       include/ragfs_ffi.h      # the C header (cbindgen-generated, hand-maintained here)
       README.md / LICENSE
```

Go/cgo embedding only needs the `-lib` archive.

## Building locally

```bash
# staticlib + header
cargo build --release -p ragfs-ffi
```

The C header is maintained by hand at `include/ragfs_ffi.h` (mirrors the
cbindgen output). Regenerate with:

```sh
cd crates/ragfs-ffi && cbindgen --config cbindgen.toml --output include/ragfs_ffi.h
```

## Embedding into Go via cgo

Download the archive for your platform and unzip/untar it. Then declare the
cgo preamble in a `.go` file. Example:

```go
//go:build cgo

/*
#cgo CFLAGS: -I/path/to/release/include
#cgo LDFLAGS: -L/path/to/release/lib -lragfs_ffi -lpthread -ldl -lm
#include <ragfs_ffi.h>
#include <stdlib.h>
*/
import "C"
```

### C ABI

The exported symbols use the `viking_*` prefix (canonical OpenViking naming,
matching `devine_cli`'s `vikingfs_*` convention); the staticlib file name
`libragfs_ffi.a` / `ragfs_ffi.lib` is unchanged:

```c
void *viking_fs_open(const char *base_path);
void  viking_fs_close(void *handle);
void *viking_fs_get(void *handle, const char *path, uint64_t *out_len);
int   viking_fs_put(void *handle, const char *path, const void *data, size_t len);
int   viking_fs_mkdir(void *handle, const char *path, int mode);
int   viking_fs_delete(void *handle, const char *path);
char *viking_fs_list(void *handle, const char *path);
const char *viking_last_error(void);
void  viking_free(void *ptr);
```

Notes:

- `viking_fs_open` returns an opaque handle; close it with `viking_fs_close`.
  The base path **must already exist** (`LocalFileSystem::new` rejects a
  missing root).
- `viking_fs_list` returns a JSON array of `{"name","size","is_dir"}` — parse
  with `encoding/json`.
- Buffers/strings returned by `viking_fs_*` are malloc-allocated; free them with
  `viking_free`.
- On any error, call `viking_last_error()` for a thread-local message.
- `viking_fs_put` auto-creates parent directories and uses create-or-truncate
  semantics (POSIX `O_CREAT`).

See `examples/ragfs_go/main.go` for a complete, runnable working example, and
`docs/embedding-go.md` for the full embedding guide (including release-archive
consumption).
