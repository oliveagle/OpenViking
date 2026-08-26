# ragfs_go — Go embedding example

Demonstrates embedding `ragfs` (the OpenViking `LocalFileSystem`) into a Go
binary via cgo, against the `crates/ragfs-ffi` staticlib.

## Prerequisites

1. Rust toolchain (builds the staticlib).
2. Go 1.25+ with `CGO_ENABLED=1` (default on unix; set explicitly on Windows).
3. A C toolchain: Xcode CLT on macOS, `gcc`/`musl-gcc` on Linux, MSVC on
   Windows (matches the target the staticlib was built for).

## Build & run

From the repo root:

```sh
cargo build --release -p ragfs-ffi
go run ./examples/ragfs_go      # requires CGO_ENABLED=1 on Windows
```

Expected output:

```
get  docs/notes.txt -> "hello from ragfs via cgo"
list docs       size=96   dir=true
delete docs/notes.txt -> gone
ok
```

## How it links

`main.go` uses these cgo directives:

```go
#cgo CFLAGS:  -I${SRCDIR}/../../crates/ragfs-ffi/include
#cgo LDFLAGS: -L${SRCDIR}/../../target/release -lragfs_ffi -lpthread -lm
#cgo linux  LDFLAGS: -lresolv
#cgo darwin LDFLAGS: -framework Security -framework CoreFoundation -framework SystemConfiguration
```

`[lib].name = "ragfs_ffi"` fixes the staticlib file name to `libragfs_ffi.a`
(unix) / `ragfs_ffi.lib` (MSVC). The **exported C ABI uses the `viking_*`
prefix**: `viking_fs_open`, `viking_fs_get`, `viking_fs_put`,
`viking_fs_mkdir`, `viking_fs_delete`, `viking_fs_list`, plus
`viking_last_error` and `viking_free`. See
`crates/ragfs-ffi/include/ragfs_ffi.h`.

## Gotchas

- `viking_fs_open(base_path)` **requires `base_path` to already exist** —
  `LocalFileSystem::new` rejects a missing root. `os.MkdirAll` it first.
- Buffers returned by `viking_fs_get` / `viking_fs_list` are
  malloc-allocated; always `viking_free()` them (the example does this via
  `defer`).
- `viking_last_error()` is thread-local: read it on the same goroutine that
  failed, before the next `viking_*` call on that thread.
- cgo static linking: on Linux the musl release staticlib (`-lragfs_ffi`
  from the `linux-*` archive) lets you produce fully static Go binaries.
- For cross-compiling Go, you still need a C cross-toolchain (zig cc, etc.);
  `CGO_ENABLED=0` is not possible when embedding ragfs.

## Release artifacts

Prebuilt staticlibs ship in the per-platform `-lib` release archives
(`openviking-<version>-<platform>-lib.{tar.gz,zip}`) produced by
`.github/workflows/release-binaries.yml` (the `-cli` archives contain only
the ov binary). Tag `lib@<version>` publishes a **lib-only** release, so Go
embedders never need to touch the CLI archives:

```
lib/libragfs_ffi.a    # staticlib (ragfs_ffi.lib on Windows)
include/ragfs_ffi.h   # C header
```

Point `#cgo LDFLAGS: -L<extracted>/lib -lragfs_ffi` and
`#cgo CFLAGS: -I<extracted>/include` at the `-lib` archive for your target
platform.
