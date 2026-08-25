#!/usr/bin/env bash
# release-local.sh — OpenViking cross-platform binary release pipeline (local).
#
# GitHub Actions is not available on this fork, so this script is the
# authoritative "full chain": build -> package -> verify -> (optional) release.
#
# Platforms (mirrors .github/workflows/release-binaries.yml):
#   1. macos-arm64    native host build
#   2. macos-amd64    cross (rustup target x86_64-apple-darwin)
#   3. linux-amd64    musl static via cargo-zigbuild
#   4. linux-arm64    musl static via cargo-zigbuild
#   5. windows-amd64  MSVC via cargo-xwin  (Windows is amd64-only, no arm64)
#
# Per platform, TWO archives:
#   openviking-<ver>-<plat>-cli.{tar.gz,zip}   the ov CLI (ov / ov.exe)
#   openviking-<ver>-<plat>-lib.{tar.gz,zip}   ragfs-ffi staticlib for
#     embedding (lib/libragfs_ffi.a, lib/ragfs_ffi.lib on Windows) +
#     include/ragfs_ffi.h (viking_* C ABI)
# Both include README.md + LICENSE.
#
# Output:
#   dist/release/openviking-<VERSION>-<platform>-cli.{tar.gz,zip}
#   dist/release/openviking-<VERSION>-<platform>-lib.{tar.gz,zip}
#   dist/release/SHA256SUMS
#
# Usage:
#   scripts/release-local.sh [VERSION] [--release] [--skip-build]
#
#   VERSION     archive version string (default: 0.1.0)
#   --release   after building, create/update GitHub release v<VERSION>
#               (requires `gh` authenticated with write access)
#   --skip-build reuse existing target/ builds, only re-package + verify
#
# Requirements:
#   - rustup toolchain `stable` with targets: x86_64-apple-darwin,
#     x86_64-unknown-linux-musl, aarch64-unknown-linux-musl,
#     x86_64-pc-windows-msvc
#   - ~/.cargo/bin/cargo-zigbuild, ~/.cargo/bin/cargo-xwin
#   - llvm-lib on PATH (e.g. brew install llvm; cargo-xwin archives C deps
#     with it for the msvc target)
#   - zig (for linux musl), 7z or zip (for packaging), tar
set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────
VERSION="0.1.0"
DO_RELEASE=0
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --release)    DO_RELEASE=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *)            VERSION="$arg" ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
OUT_DIR="dist/release"

CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
TC_DIR="${TC_DIR:-$HOME/.rustup/toolchains/stable-aarch64-apple-darwin}"
RUSTC="$TC_DIR/bin/rustc"

echo "==> OpenViking local release pipeline"
echo "    version : $VERSION"
echo "    cargo   : $CARGO"
echo "    rustc   : $RUSTC"

# ── Preflight ─────────────────────────────────────────────────────────────────
command -v "$CARGO" >/dev/null || { echo "FATAL: $CARGO not found"; exit 1; }
[ -x "$RUSTC" ] || { echo "FATAL: rustc not found at $RUSTC (expected rustup stable toolchain)"; exit 1; }
command -v tar >/dev/null || { echo "FATAL: tar not found"; exit 1; }

# Avoid RUSTC_WRAPPER (e.g. sccache) resolving a different rustc via PATH.
unset RUSTC_WRAPPER
export RUSTC
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

# cargo-xwin links with lld-link and archives C deps with llvm-lib (COFF);
# make sure both are on PATH (Homebrew: opt/llvm@*/bin, opt/lld@*/bin).
if ! command -v lld-link >/dev/null 2>&1; then
  for d in /opt/homebrew/opt/lld@*/bin /usr/local/opt/lld@*/bin; do
    if [ -x "$d/lld-link" ]; then
      case ":$PATH:" in *":$d:"*) ;; *) export PATH="$d:$PATH" ;; esac
      break
    fi
  done
fi
if ! command -v llvm-lib >/dev/null 2>&1; then
  for d in /opt/homebrew/opt/llvm@*/bin /usr/local/opt/llvm@*/bin; do
    if [ -x "$d/llvm-lib" ]; then
      case ":$PATH:" in *":$d:"*) ;; *) export PATH="$d:$PATH" ;; esac
      break
    fi
  done
fi
command -v lld-link >/dev/null 2>&1 || echo "WARN: lld-link not found; windows-msvc linking will fail (brew install lld)"
command -v llvm-lib >/dev/null 2>&1 || echo "WARN: llvm-lib not found; windows-msvc C-dep archiving may fail (brew install llvm)"

# Check required cross-target stds are present in the toolchain (rustlib
# dir is the ground truth; install via rustup when missing).
for t in x86_64-apple-darwin x86_64-unknown-linux-musl \
        aarch64-unknown-linux-musl x86_64-pc-windows-msvc; do
  if [ ! -d "$TC_DIR/lib/rustlib/$t/lib" ]; then
    echo "    rustup target add $t"
    rustup target add "$t" --toolchain stable || {
      echo "FATAL: cannot install rust std for $t (rustup target add failed)"; exit 1; }
  fi
done

build_pkg() { # build <extra-cargo-args...> e.g. --release -p ov_cli -p ragfs-ffi
  "$CARGO" +stable build "$@"
}

# ── Build matrix ──────────────────────────────────────────────────────────────
if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> [1/5] macos-arm64 (native)"
  build_pkg --release -p ov_cli -p ragfs-ffi

  echo "==> [2/5] macos-amd64 (cross)"
  build_pkg --release --target x86_64-apple-darwin -p ov_cli -p ragfs-ffi

  echo "==> [3/5] linux-amd64 (musl, zigbuild)"
  command -v cargo-zigbuild >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/cargo-zigbuild" ] \
    || { echo "FATAL: cargo-zigbuild not found"; exit 1; }
  "$CARGO" +stable zigbuild --release --target x86_64-unknown-linux-musl -p ov_cli -p ragfs-ffi

  echo "==> [4/5] linux-arm64 (musl, zigbuild)"
  "$CARGO" +stable zigbuild --release --target aarch64-unknown-linux-musl -p ov_cli -p ragfs-ffi

  echo "==> [5/5] windows-amd64 (msvc, xwin)"
  command -v cargo-xwin >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/cargo-xwin" ] \
    || { echo "FATAL: cargo-xwin not found (cargo install cargo-xwin)"; exit 1; }
  "$CARGO" +stable xwin build --release --target x86_64-pc-windows-msvc -p ov_cli -p ragfs-ffi
else
  echo "==> --skip-build: reusing existing target/ builds"
fi

# ── Package ───────────────────────────────────────────────────────────────────
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE_ROOT"' EXIT

# make_archive <staging-dir> <archive-name>: zip via 7z, else tar.gz
make_archive() {
  local dir="$1"
  local name="$2"
  local abs="$REPO_ROOT/$OUT_DIR/$name"
  if [[ "$name" == *.zip ]]; then
    if command -v 7z >/dev/null 2>&1; then
      (cd "$dir" && 7z a -bso0 "$abs" . >/dev/null)
    else
      (cd "$dir" && zip -qry "$abs" .)
    fi
  else
    tar -czf "$abs" -C "$dir" .
  fi
}

package_split() { # <name> <target> <ov_binary> <ffi_lib_name> <ext>
  local name="$1" target="$2" ovbin="$3" ffi="$4" ext="$5"
  local base="openviking-$VERSION-$name"

  # --- CLI archive ---
  local stg_cli="$STAGE_ROOT/$name-cli"
  mkdir -p "$stg_cli"
  cp "target/$target/release/$ovbin" "$stg_cli/"
  [ "$ext" != "zip" ] && chmod +x "$stg_cli/$ovbin"
  for f in README.md LICENSE; do [ -f "$f" ] && cp "$f" "$stg_cli/"; done
  chmod -R u+rw "$stg_cli"
  make_archive "$stg_cli" "$base-cli.$ext"

  # --- LIB archive (staticlib + header) ---
  # rustc emits libragfs_ffi.a (ar) on unix and ragfs_ffi.lib (COFF) on
  # the msvc target; $ffi matches the on-disk name.
  local stg_lib="$STAGE_ROOT/$name-lib"
  mkdir -p "$stg_lib/lib" "$stg_lib/include"
  cp "target/$target/release/$ffi" "$stg_lib/lib/"
  cp "crates/ragfs-ffi/include/ragfs_ffi.h" "$stg_lib/include/"
  for f in README.md LICENSE; do [ -f "$f" ] && cp "$f" "$stg_lib/"; done
  chmod -R u+rw "$stg_lib"
  make_archive "$stg_lib" "$base-lib.$ext"

  echo "    packaged: $base-cli.$ext + $base-lib.$ext"
}

echo "==> Packaging"
package_split macos-arm64   aarch64-apple-darwin      ov      libragfs_ffi.a tar.gz
package_split macos-amd64   x86_64-apple-darwin       ov      libragfs_ffi.a tar.gz
package_split linux-amd64   x86_64-unknown-linux-musl ov      libragfs_ffi.a tar.gz
package_split linux-arm64   aarch64-unknown-linux-musl ov     libragfs_ffi.a tar.gz
package_split windows-amd64 x86_64-pc-windows-msvc    ov.exe  ragfs_ffi.lib  zip

# ── Checksums ─────────────────────────────────────────────────────────────────
echo "==> SHA256SUMS"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OUT_DIR" && sha256sum openviking-*.tar.gz openviking-*.zip > SHA256SUMS)
else
  (cd "$OUT_DIR" && shasum -a 256 openviking-*.tar.gz openviking-*.zip > SHA256SUMS)
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo "==> Verify"
extract_archive() { # <archive> <ext> <tmp-dir>
  local archive="$1" ext="$2" tmp="$3"
  if [ "$ext" = "zip" ]; then
    7z x -y -o"$tmp" "$REPO_ROOT/$archive" >/dev/null
  else
    tar -xzf "$REPO_ROOT/$archive" -C "$tmp"
  fi
}

verify_cli() { # <archive> <ext> <ovbin>
  local archive="$1" ext="$2" ovbin="$3"
  local tmp; tmp="$(mktemp -d)"
  extract_archive "$archive" "$ext" "$tmp"
  [ -s "$tmp/$ovbin" ] || { echo "FATAL: $ovbin missing in $archive"; rm -rf "$tmp"; exit 1; }
  echo "    OK: $(basename "$archive") ($(du -h "$REPO_ROOT/$archive" | cut -f1))"
  rm -rf "$tmp"
}

verify_lib() { # <archive> <ext> <ffi>
  local archive="$1" ext="$2" ffi="$3"
  local tmp; tmp="$(mktemp -d)"
  extract_archive "$archive" "$ext" "$tmp"
  # staticlib present and contains the viking_* ABI (symbol names are plain
  # strings in every object format, so grep works on GNU/COFF/Apple archives)
  [ -s "$tmp/lib/$ffi" ] || { echo "FATAL: lib/$ffi missing in $archive"; rm -rf "$tmp"; exit 1; }
  grep -q "viking_fs_open" "$tmp/lib/$ffi" || { echo "FATAL: viking_fs_open symbol missing in $archive"; rm -rf "$tmp"; exit 1; }
  grep -q "viking_fs_put" "$tmp/lib/$ffi" || { echo "FATAL: viking_fs_put symbol missing in $archive"; rm -rf "$tmp"; exit 1; }
  [ -s "$tmp/include/ragfs_ffi.h" ] || { echo "FATAL: include/ragfs_ffi.h missing in $archive"; rm -rf "$tmp"; exit 1; }
  echo "    OK: $(basename "$archive") ($(du -h "$REPO_ROOT/$archive" | cut -f1))"
  rm -rf "$tmp"
}
# CLI archives: binary present
for pl in macos-arm64 macos-amd64 linux-amd64 linux-arm64; do
  verify_cli "$OUT_DIR/openviking-$VERSION-$pl-cli.tar.gz" tar.gz ov
done
verify_cli "$OUT_DIR/openviking-$VERSION-windows-amd64-cli.zip" zip ov.exe
# LIB archives: staticlib + symbols + header
for pl in macos-arm64 macos-amd64 linux-amd64 linux-arm64; do
  verify_lib "$OUT_DIR/openviking-$VERSION-$pl-lib.tar.gz" tar.gz libragfs_ffi.a
done
verify_lib "$OUT_DIR/openviking-$VERSION-windows-amd64-lib.zip" zip ragfs_ffi.lib

# Host smoke test: run the native binary if the host matches macos-arm64
if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
  if "$REPO_ROOT/target/aarch64-apple-darwin/release/ov" --version >/dev/null 2>&1; then
    echo "    OK: host smoke test (ov --version)"
  else
    echo "FATAL: host smoke test failed (ov --version)"; exit 1
  fi
fi

echo "==> Done. Artifacts in $OUT_DIR:"
ls -lh "$OUT_DIR"

# ── Optional GitHub release ───────────────────────────────────────────────────
if [ "$DO_RELEASE" -eq 1 ]; then
  echo "==> Creating GitHub release v$VERSION"
  command -v gh >/dev/null || { echo "FATAL: gh not found"; exit 1; }
  NOTES_FILE="$(mktemp)"
  {
    echo "## OpenViking v$VERSION — cross-platform binaries"
    echo ""
    echo "Per platform, two archives: \`-cli\` (ov binary) and \`-lib\` (ragfs-ffi staticlib + C header)."
    echo ""
    echo "| Platform | CLI archive | LIB archive |"
    echo "|---|---|---|"
    echo "| linux/amd64 | \`openviking-$VERSION-linux-amd64-cli.tar.gz\` | \`...-lib.tar.gz\` (\`lib/libragfs_ffi.a\`, static musl) |"
    echo "| linux/arm64 | \`openviking-$VERSION-linux-arm64-cli.tar.gz\` | \`...-lib.tar.gz\` (\`lib/libragfs_ffi.a\`, static musl) |"
    echo "| macos/amd64 | \`openviking-$VERSION-macos-amd64-cli.tar.gz\` | \`...-lib.tar.gz\` (\`lib/libragfs_ffi.a\`) |"
    echo "| macos/arm64 | \`openviking-$VERSION-macos-arm64-cli.tar.gz\` | \`...-lib.tar.gz\` (\`lib/libragfs_ffi.a\`) |"
    echo "| windows/amd64 | \`openviking-$VERSION-windows-amd64-cli.zip\` (\`ov.exe\`, MSVC) | \`...-lib.zip\` (\`lib/ragfs_ffi.lib\`, COFF) |"
    echo ""
    echo "Embedding into Go? You only need the \`-lib\` archive — see \`docs/embedding-go.md\` and \`examples/ragfs_go\`."
    echo ""
    echo "Checksums: see \`SHA256SUMS\`."
  } > "$NOTES_FILE"
  gh release create "v$VERSION" \
    --target "$(git rev-parse HEAD)" \
    --title "OpenViking v$VERSION" \
    --notes-file "$NOTES_FILE" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-linux-amd64-cli.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-linux-amd64-lib.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-linux-arm64-cli.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-linux-arm64-lib.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-macos-amd64-cli.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-macos-amd64-lib.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-macos-arm64-cli.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-macos-arm64-lib.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-windows-amd64-cli.zip" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-windows-amd64-lib.zip" \
    "$REPO_ROOT/$OUT_DIR/SHA256SUMS"
  rm -f "$NOTES_FILE"
  echo "==> Release v$VERSION created"
fi
