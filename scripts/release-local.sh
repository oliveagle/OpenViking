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
# Per-platform archive contents:
#   ov | ov.exe            the OpenViking CLI
#   lib/libragfs_ffi.a     ragfs-ffi staticlib (lib/ragfs_ffi.lib on Windows)
#   include/ragfs_ffi.h    C header (viking_* ABI)
#   README.md LICENSE
#
# Output:
#   dist/release/openviking-<VERSION>-<platform>.{tar.gz,zip}
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

package_one() { # <name> <target> <ov_binary> <ffi_lib_name> <archive_ext>
  local name="$1" target="$2" ovbin="$3" ffi="$4" ext="$5"
  local staging="$STAGE_ROOT/$name"
  mkdir -p "$staging/lib" "$staging/include"

  cp "target/$target/release/$ovbin" "$staging/"
  if [ "$ext" != "zip" ]; then chmod +x "$staging/$ovbin"; fi

  # rustc emits libragfs_ffi.a (ar archive) on unix targets and
  # ragfs_ffi.lib (COFF archive) on the msvc target; $ffi matches the
  # on-disk name, so copy it as-is into lib/.
  cp "target/$target/release/$ffi" "$staging/lib/"
  cp "crates/ragfs-ffi/include/ragfs_ffi.h" "$staging/include/"
  for f in README.md LICENSE; do [ -f "$f" ] && cp "$f" "$staging/"; done
  chmod -R u+rw "$staging"

  # Absolute path: the zip step runs from inside a temp staging dir.
  local archive="$REPO_ROOT/$OUT_DIR/openviking-$VERSION-$name.$ext"
  if [ "$ext" = "zip" ]; then
    if command -v 7z >/dev/null 2>&1; then
      (cd "$staging" && 7z a -bso0 "$archive" . >/dev/null)
    else
      (cd "$staging" && zip -qry "$archive" .)
    fi
  else
    tar -czf "$archive" -C "$staging" .
  fi
  echo "    packaged: ${archive#"$REPO_ROOT"/}"
}

echo "==> Packaging"
package_one macos-arm64   aarch64-apple-darwin      ov      libragfs_ffi.a tar.gz
package_one macos-amd64   x86_64-apple-darwin       ov      libragfs_ffi.a tar.gz
package_one linux-amd64   x86_64-unknown-linux-musl ov      libragfs_ffi.a tar.gz
package_one linux-arm64   aarch64-unknown-linux-musl ov     libragfs_ffi.a tar.gz
package_one windows-amd64 x86_64-pc-windows-msvc    ov.exe  ragfs_ffi.lib  zip

# ── Checksums ─────────────────────────────────────────────────────────────────
echo "==> SHA256SUMS"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OUT_DIR" && sha256sum openviking-*.tar.gz openviking-*.zip > SHA256SUMS)
else
  (cd "$OUT_DIR" && shasum -a 256 openviking-*.tar.gz openviking-*.zip > SHA256SUMS)
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo "==> Verify"
verify_archive() { # <archive> <ext> <ovbin> <ffi>
  local archive="$1" ext="$2" ovbin="$3" ffi="$4"
  local tmp; tmp="$(mktemp -d)"
  if [ "$ext" = "zip" ]; then
    unzip -q "$REPO_ROOT/$archive" -d "$tmp" 2>/dev/null || 7z x -y -o"$tmp" "$REPO_ROOT/$archive" >/dev/null
  else
    tar -xzf "$REPO_ROOT/$archive" -C "$tmp"
  fi
  # binary present
  [ -s "$tmp/$ovbin" ] || { echo "FATAL: $ovbin missing in $archive"; rm -rf "$tmp"; exit 1; }
  # staticlib present and contains the viking_* ABI (symbol names are plain
  # strings in every object format, so grep works on GNU/COFF/Apple archives)
  [ -s "$tmp/lib/$ffi" ] || { echo "FATAL: lib/$ffi missing in $archive"; rm -rf "$tmp"; exit 1; }
  grep -q "viking_fs_open" "$tmp/lib/$ffi" || { echo "FATAL: viking_fs_open symbol missing in $archive"; rm -rf "$tmp"; exit 1; }
  grep -q "viking_fs_put" "$tmp/lib/$ffi" || { echo "FATAL: viking_fs_put symbol missing in $archive"; rm -rf "$tmp"; exit 1; }
  [ -s "$tmp/include/ragfs_ffi.h" ] || { echo "FATAL: include/ragfs_ffi.h missing in $archive"; rm -rf "$tmp"; exit 1; }
  echo "    OK: $(basename "$archive") ($(du -h "$archive" | cut -f1))"
  rm -rf "$tmp"
}
verify_archive "$OUT_DIR/openviking-$VERSION-macos-arm64.tar.gz"  tar.gz ov      libragfs_ffi.a
verify_archive "$OUT_DIR/openviking-$VERSION-macos-amd64.tar.gz"  tar.gz ov      libragfs_ffi.a
verify_archive "$OUT_DIR/openviking-$VERSION-linux-amd64.tar.gz"  tar.gz ov      libragfs_ffi.a
verify_archive "$OUT_DIR/openviking-$VERSION-linux-arm64.tar.gz"  tar.gz ov      libragfs_ffi.a
verify_archive "$OUT_DIR/openviking-$VERSION-windows-amd64.zip"   zip    ov.exe  ragfs_ffi.lib

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
    echo "| Platform | CLI | ragfs-ffi staticlib |"
    echo "|---|---|---|"
    echo "| linux/amd64 | \`ov\` (static musl) | \`lib/libragfs_ffi.a\` |"
    echo "| linux/arm64 | \`ov\` (static musl) | \`lib/libragfs_ffi.a\` |"
    echo "| macos/amd64 | \`ov\` | \`lib/libragfs_ffi.a\` |"
    echo "| macos/arm64 | \`ov\` | \`lib/libragfs_ffi.a\` |"
    echo "| windows/amd64 | \`ov.exe\` (MSVC) | \`lib/ragfs_ffi.lib\` |"
    echo ""
    echo "Embed the staticlib into Go via cgo — see \`docs/embedding-go.md\` and \`examples/ragfs_go\`."
    echo ""
    echo "Checksums: see \`SHA256SUMS\`."
  } > "$NOTES_FILE"
  gh release create "v$VERSION" \
    --target "$(git rev-parse HEAD)" \
    --title "OpenViking v$VERSION" \
    --notes-file "$NOTES_FILE" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-linux-amd64.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-linux-arm64.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-macos-amd64.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-macos-arm64.tar.gz" \
    "$REPO_ROOT/$OUT_DIR/openviking-$VERSION-windows-amd64.zip" \
    "$REPO_ROOT/$OUT_DIR/SHA256SUMS"
  rm -f "$NOTES_FILE"
  echo "==> Release v$VERSION created"
fi
