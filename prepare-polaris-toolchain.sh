#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KERNEL_BUILD_ROOT=$(cd -- "$SCRIPT_ROOT/.." && pwd)
CLANG_REPOSITORY=https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86
CLANG_TAG=android-15.0.0_r32
CLANG_COMMIT=96266255abde668f1bf100bf2c47363b96b7a21e
CLANG_VERSION=clang-r536225
TARGET_DIR="$KERNEL_BUILD_ROOT/android_prebuilts_clang_host_linux-x86"

usage() {
    cat <<EOF
Usage: $(basename -- "$0") [--target-dir PATH]

Deploy and verify the AOSP Clang toolchain used by LineageOS 22.2.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --target-dir)
            (($# >= 2)) || die "--target-dir requires a path"
            TARGET_DIR=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

TARGET_DIR=$(realpath -m -- "$TARGET_DIR")

verify_toolchain() {
    local clang_dir="$TARGET_DIR/$CLANG_VERSION"
    local commit
    local remote
    local version

    [[ -d "$TARGET_DIR/.git" ]] || die "toolchain repository metadata is missing: $TARGET_DIR"
    commit=$(git -C "$TARGET_DIR" rev-parse HEAD)
    [[ "$commit" == "$CLANG_COMMIT" ]] || die "unexpected commit: $commit"
    remote=$(git -C "$TARGET_DIR" remote get-url origin)
    [[ "$remote" == "$CLANG_REPOSITORY" ]] || die "unexpected repository: $remote"
    [[ -z "$(git -C "$TARGET_DIR" status --porcelain)" ]] || die "toolchain repository is dirty"
    [[ -x "$clang_dir/bin/clang" ]] || die "clang is missing"
    [[ -x "$clang_dir/bin/ld.lld" ]] || die "ld.lld is missing"
    [[ -x "$clang_dir/bin/llvm-ar" ]] || die "llvm-ar is missing"
    [[ -x "$clang_dir/bin/llvm-objcopy" ]] || die "llvm-objcopy is missing"
    version=$("$clang_dir/bin/clang" --version | head -n 1)
    [[ "$version" == *"based on r536225"* && "$version" == *"clang version 19.0.1"* ]] || die "unexpected clang version: $version"

    printf 'repository: %s\n' "$remote"
    printf 'commit: %s\n' "$commit"
    printf 'version: %s\n' "$version"
    sha256sum "$clang_dir/bin/clang.real" "$clang_dir/bin/lld" "$clang_dir/bin/llvm-ar"
}

if [[ -e "$TARGET_DIR" ]]; then
    verify_toolchain
    exit 0
fi

PARTIAL_DIR="$TARGET_DIR.partial.$$"
[[ ! -e "$PARTIAL_DIR" ]] || die "partial directory already exists: $PARTIAL_DIR"

git clone --depth 1 --filter=blob:none --no-checkout \
    --branch "$CLANG_TAG" --single-branch \
    "$CLANG_REPOSITORY" "$PARTIAL_DIR"
git -C "$PARTIAL_DIR" sparse-checkout init --cone
git -C "$PARTIAL_DIR" sparse-checkout set "$CLANG_VERSION"
git -C "$PARTIAL_DIR" checkout --detach "$CLANG_COMMIT"
mv -- "$PARTIAL_DIR" "$TARGET_DIR"

verify_toolchain
