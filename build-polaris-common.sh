#!/usr/bin/env bash
set -euo pipefail

POLARIS_SCRIPT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
POLARIS_KERNEL_BUILD_ROOT=$(cd -- "$POLARIS_SCRIPT_ROOT/.." && pwd)
POLARIS_CLANG_VERSION=${POLARIS_CLANG_VERSION:-clang-r536225}
POLARIS_CLANG_COMMIT=${POLARIS_CLANG_COMMIT:-96266255abde668f1bf100bf2c47363b96b7a21e}
POLARIS_CLANG_REPOSITORY=${POLARIS_CLANG_REPOSITORY:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}
POLARIS_CLANG_REPO_DIR=${POLARIS_CLANG_REPO_DIR:-"$POLARIS_KERNEL_BUILD_ROOT/android_prebuilts_clang_host_linux-x86"}
POLARIS_CLANG_DIR=${POLARIS_CLANG_DIR:-"$POLARIS_CLANG_REPO_DIR/$POLARIS_CLANG_VERSION"}
POLARIS_GCC64_DIR=${POLARIS_GCC64_DIR:-"$POLARIS_KERNEL_BUILD_ROOT/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9"}
POLARIS_GCC32_DIR=${POLARIS_GCC32_DIR:-"$POLARIS_KERNEL_BUILD_ROOT/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9"}
POLARIS_GCC64_VIEW_DIR=${POLARIS_GCC64_VIEW_DIR:-"$POLARIS_KERNEL_BUILD_ROOT/polaris-build-tools/aarch64-linux-android-4.9"}
POLARIS_MKBOOTIMG_DIR=${POLARIS_MKBOOTIMG_DIR:-"$POLARIS_KERNEL_BUILD_ROOT/mkbootimg"}

polaris_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

polaris_usage() {
    cat <<EOF
Usage: $(basename -- "$0") [boot.img] [options]

Options:
  --boot PATH         Official boot image used as the ramdisk/header base
  --jobs NUMBER       Parallel build jobs (default: 8)
  --output-dir PATH   Image, config and log output directory
  --out-dir PATH      Kernel object output directory
  --config-only       Generate and validate .config without compiling
  -h, --help          Show this help
EOF
}

polaris_parse_args() {
    POLARIS_BOOT_IMAGE=${POLARIS_BOOT_IMAGE:-}
    POLARIS_JOBS=${POLARIS_JOBS:-8}
    POLARIS_OUTPUT_DIR=${POLARIS_OUTPUT_DIR:-"$POLARIS_KERNEL_BUILD_ROOT/polaris-build-dist-r536225"}
    POLARIS_OUT_DIR=${POLARIS_OUT_DIR:-"$POLARIS_KERNEL_BUILD_ROOT/polaris-build-out/current"}
    POLARIS_CONFIG_ONLY=0

    while (($#)); do
        case "$1" in
            --boot)
                (($# >= 2)) || polaris_die "--boot requires a path"
                POLARIS_BOOT_IMAGE=$2
                shift 2
                ;;
            --jobs)
                (($# >= 2)) || polaris_die "--jobs requires a number"
                POLARIS_JOBS=$2
                shift 2
                ;;
            --output-dir)
                (($# >= 2)) || polaris_die "--output-dir requires a path"
                POLARIS_OUTPUT_DIR=$2
                shift 2
                ;;
            --out-dir)
                (($# >= 2)) || polaris_die "--out-dir requires a path"
                POLARIS_OUT_DIR=$2
                shift 2
                ;;
            --config-only)
                POLARIS_CONFIG_ONLY=1
                shift
                ;;
            -h|--help)
                polaris_usage
                exit 0
                ;;
            --*)
                polaris_die "unknown option: $1"
                ;;
            *)
                [[ -z "$POLARIS_BOOT_IMAGE" ]] || polaris_die "unexpected argument: $1"
                POLARIS_BOOT_IMAGE=$1
                shift
                ;;
        esac
    done

    [[ "$POLARIS_JOBS" =~ ^[1-9][0-9]*$ ]] || polaris_die "jobs must be a positive integer"
    if ((POLARIS_CONFIG_ONLY == 0)); then
        [[ -n "$POLARIS_BOOT_IMAGE" ]] || polaris_die "an official boot.img is required"
        [[ -f "$POLARIS_BOOT_IMAGE" ]] || polaris_die "boot image not found: $POLARIS_BOOT_IMAGE"
        POLARIS_BOOT_IMAGE=$(realpath -- "$POLARIS_BOOT_IMAGE")
    fi

    mkdir -p "$POLARIS_OUTPUT_DIR" "$POLARIS_OUT_DIR"
    POLARIS_OUTPUT_DIR=$(cd -- "$POLARIS_OUTPUT_DIR" && pwd)
    POLARIS_OUT_DIR=$(cd -- "$POLARIS_OUT_DIR" && pwd)
    POLARIS_BUILD_ID=$(date +%Y%m%d-%H%M%S)
}

polaris_require_tracked_clean() {
    local source_root=$1

    git -C "$source_root" diff --quiet --ignore-submodules -- || polaris_die "tracked source changes must be committed or restored"
    git -C "$source_root" diff --cached --quiet --ignore-submodules -- || polaris_die "staged source changes must be committed or restored"
}

polaris_prepare_gcc64_view() {
    local source_entry
    local entry_name
    local target_entry

    mkdir -p "$POLARIS_GCC64_VIEW_DIR/bin"

    for source_entry in "$POLARIS_GCC64_DIR"/*; do
        entry_name=$(basename -- "$source_entry")
        [[ "$entry_name" == bin ]] && continue
        target_entry="$POLARIS_GCC64_VIEW_DIR/$entry_name"
        [[ ! -e "$target_entry" || -L "$target_entry" ]] || polaris_die "unexpected GCC view entry: $target_entry"
        ln -sfn -- "$source_entry" "$target_entry"
    done

    for source_entry in "$POLARIS_GCC64_DIR"/bin/*; do
        entry_name=$(basename -- "$source_entry")
        target_entry="$POLARIS_GCC64_VIEW_DIR/bin/$entry_name"
        [[ ! -e "$target_entry" || -L "$target_entry" ]] || polaris_die "unexpected GCC view tool: $target_entry"
        case "$entry_name" in
            aarch64-linux-android-gcc)
                source_entry="$POLARIS_GCC64_DIR/bin/real-aarch64-linux-android-gcc"
                ;;
            aarch64-linux-android-g++)
                source_entry="$POLARIS_GCC64_DIR/bin/real-aarch64-linux-android-g++"
                ;;
        esac
        ln -sfn -- "$source_entry" "$target_entry"
    done
}

polaris_prepare_environment() {
    local clang_bin="$POLARIS_CLANG_DIR/bin/clang"
    local gcc64_prefix="$POLARIS_GCC64_VIEW_DIR/bin/aarch64-linux-android-"
    local gcc32_prefix="$POLARIS_GCC32_DIR/bin/arm-linux-androidkernel-"
    local clang_commit
    local clang_remote
    local clang_version

    [[ -x "$clang_bin" ]] || polaris_die "clang not found: $clang_bin"
    [[ -x "$POLARIS_CLANG_DIR/bin/ld.lld" ]] || polaris_die "ld.lld not found"
    [[ -x "$POLARIS_CLANG_DIR/bin/llvm-ar" ]] || polaris_die "llvm-ar not found"
    [[ -x "$POLARIS_CLANG_DIR/bin/llvm-objcopy" ]] || polaris_die "llvm-objcopy not found"
    [[ -x "$POLARIS_GCC64_DIR/bin/real-aarch64-linux-android-gcc" ]] || polaris_die "64-bit GCC binary not found"
    [[ -x "${gcc32_prefix}ld" ]] || polaris_die "32-bit GNU binutils not found: ${gcc32_prefix}ld"
    [[ -f "$POLARIS_MKBOOTIMG_DIR/unpack_bootimg.py" ]] || polaris_die "unpack_bootimg.py is missing"
    [[ -f "$POLARIS_MKBOOTIMG_DIR/mkbootimg.py" ]] || polaris_die "mkbootimg.py is missing"
    command -v cmp >/dev/null || polaris_die "cmp is not installed"
    command -v git >/dev/null || polaris_die "git is not installed"
    command -v make >/dev/null || polaris_die "make is not installed"
    command -v python3 >/dev/null || polaris_die "python3 is not installed"
    command -v sha256sum >/dev/null || polaris_die "sha256sum is not installed"

    [[ -d "$POLARIS_CLANG_REPO_DIR/.git" ]] || polaris_die "clang repository metadata is missing"
    clang_commit=$(git -C "$POLARIS_CLANG_REPO_DIR" rev-parse HEAD)
    [[ "$clang_commit" == "$POLARIS_CLANG_COMMIT" ]] || polaris_die "unexpected clang commit: $clang_commit"
    clang_remote=$(git -C "$POLARIS_CLANG_REPO_DIR" remote get-url origin)
    [[ "$clang_remote" == "$POLARIS_CLANG_REPOSITORY" ]] || polaris_die "unexpected clang repository: $clang_remote"
    [[ -z "$(git -C "$POLARIS_CLANG_REPO_DIR" status --porcelain)" ]] || polaris_die "clang repository is dirty"
    clang_version=$("$clang_bin" --version | head -n 1)
    [[ "$clang_version" == *"based on r536225"* && "$clang_version" == *"clang version 19.0.1"* ]] || polaris_die "unexpected clang version: $clang_version"

    polaris_prepare_gcc64_view
    [[ -x "${gcc64_prefix}gcc" ]] || polaris_die "64-bit GCC view is incomplete"
    [[ -x "${gcc64_prefix}elfedit" ]] || polaris_die "64-bit GNU binutils view is incomplete"

    export PATH="$POLARIS_CLANG_DIR/bin:$POLARIS_GCC64_VIEW_DIR/bin:$POLARIS_GCC32_DIR/bin:$PATH"
    export LD_LIBRARY_PATH="$POLARIS_CLANG_DIR/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export ARCH=arm64
    export SUBARCH=arm64
    export TMPDIR=${POLARIS_TMPDIR:-/tmp/polaris-build-tmp}
    export TMP=$TMPDIR
    export TEMP=$TMPDIR
    mkdir -p "$TMPDIR"

    POLARIS_MAKE_ARGS=(
        O="$POLARIS_OUT_DIR"
        ARCH=arm64
        CC=clang
        HOSTCC="$POLARIS_CLANG_DIR/bin/clang"
        HOSTCXX="$POLARIS_CLANG_DIR/bin/clang++"
        LD="$POLARIS_CLANG_DIR/bin/ld.lld"
        AR="$POLARIS_CLANG_DIR/bin/llvm-ar"
        LLVM=1
        LLVM_IAS=1
        CLANG_TRIPLE=aarch64-linux-gnu-
        CROSS_COMPILE="$gcc64_prefix"
        CROSS_COMPILE_ARM32="$gcc32_prefix"
        CROSS_COMPILE_COMPAT="$gcc32_prefix"
    )
}

polaris_write_toolchain_manifest() {
    local source_root=$1
    local manifest_file=$2
    local clang_version
    local lld_version
    local source_status

    clang_version=$("$POLARIS_CLANG_DIR/bin/clang" --version | head -n 1)
    lld_version=$("$POLARIS_CLANG_DIR/bin/ld.lld" --version | head -n 1)
    source_status=$(git -C "$source_root" status --short --untracked-files=no | tr '\n' ';')

    {
        printf 'variant=%s\n' "$POLARIS_VARIANT"
        printf 'build_id=%s\n' "$POLARIS_BUILD_ID"
        printf 'source_commit=%s\n' "$(git -C "$source_root" rev-parse HEAD)"
        printf 'source_status=%s\n' "${source_status:-clean}"
        printf 'clang_repository=%s\n' "$POLARIS_CLANG_REPOSITORY"
        printf 'clang_commit=%s\n' "$(git -C "$POLARIS_CLANG_REPO_DIR" rev-parse HEAD)"
        printf 'clang_version=%s\n' "$clang_version"
        printf 'lld_version=%s\n' "$lld_version"
        printf 'gcc64_binutils=%s\n' "$("$POLARIS_GCC64_DIR/bin/aarch64-linux-android-ld" --version | head -n 1)"
        printf 'gcc64_view=%s\n' "$POLARIS_GCC64_VIEW_DIR"
        printf 'gcc32_binutils=%s\n' "$("$POLARIS_GCC32_DIR/bin/arm-linux-androidkernel-ld" --version | head -n 1)"
        if [[ "$POLARIS_VARIANT" == ksu ]]; then
            printf 'kernelsu_repository=%s\n' "$KERNELSU_REPOSITORY"
            printf 'kernelsu_tag=%s\n' "$KERNELSU_TAG"
            printf 'kernelsu_commit=%s\n' "$KERNELSU_COMMIT"
        fi
        printf 'make_args='
        printf '%q ' "${POLARIS_MAKE_ARGS[@]}"
        printf '\n'
        if [[ -n "$POLARIS_BOOT_IMAGE" ]]; then
            sha256sum "$POLARIS_BOOT_IMAGE"
        fi
    } > "$manifest_file"
}

polaris_require_enabled() {
    local config_file=$1
    local symbol=$2

    grep -qx "CONFIG_${symbol}=y" "$config_file" || polaris_die "CONFIG_${symbol}=y was not generated"
}

polaris_require_not_enabled() {
    local config_file=$1
    local symbol=$2

    if grep -qE "^CONFIG_${symbol}=(y|m)$" "$config_file"; then
        polaris_die "CONFIG_${symbol} must not be enabled"
    fi
}

polaris_validate_config() {
    local config_file=$1

    polaris_require_enabled "$config_file" AUDIT
    polaris_require_enabled "$config_file" IKCONFIG
    polaris_require_enabled "$config_file" IKCONFIG_PROC
    polaris_require_enabled "$config_file" PERF_EVENTS
    polaris_require_enabled "$config_file" SECURITY_SELINUX

    if [[ "$POLARIS_VARIANT" == ksu ]]; then
        polaris_require_enabled "$config_file" KSU
        polaris_require_enabled "$config_file" KPROBES
        polaris_require_enabled "$config_file" HAVE_KPROBES
    else
        polaris_require_not_enabled "$config_file" KSU
        polaris_require_not_enabled "$config_file" KPROBES
        polaris_require_not_enabled "$config_file" KPROBE_EVENTS
    fi
}

polaris_build_kernel() {
    local source_root=$1
    local config_fragment=${2:-}
    local config_file="$POLARIS_OUT_DIR/.config"
    local log_file="$POLARIS_OUTPUT_DIR/polaris-$POLARIS_VARIANT-$POLARIS_BUILD_ID.log"
    local config_snapshot="$POLARIS_OUTPUT_DIR/polaris-$POLARIS_VARIANT-$POLARIS_BUILD_ID.config"
    local toolchain_manifest="$POLARIS_OUTPUT_DIR/polaris-$POLARIS_VARIANT-$POLARIS_BUILD_ID.toolchain.txt"

    [[ -f "$source_root/arch/arm64/configs/polaris_final_defconfig" ]] || polaris_die "polaris_final_defconfig is missing"

    make -C "$source_root" "${POLARIS_MAKE_ARGS[@]}" mrproper
    make -C "$source_root" "${POLARIS_MAKE_ARGS[@]}" polaris_final_defconfig

    if [[ -n "$config_fragment" ]]; then
        [[ -f "$config_fragment" ]] || polaris_die "config fragment not found: $config_fragment"
        (
            cd -- "$source_root"
            KCONFIG_CONFIG="$config_file" scripts/kconfig/merge_config.sh -m -O "$POLARIS_OUT_DIR" "$config_file" "$config_fragment"
        )
        make -C "$source_root" "${POLARIS_MAKE_ARGS[@]}" olddefconfig
    fi

    polaris_validate_config "$config_file"
    cp -- "$config_file" "$config_snapshot"
    polaris_write_toolchain_manifest "$source_root" "$toolchain_manifest"
    printf 'config: %s\n' "$config_snapshot"
    printf 'toolchain: %s\n' "$toolchain_manifest"

    if ((POLARIS_CONFIG_ONLY)); then
        return 0
    fi

    make -C "$source_root" -j"$POLARIS_JOBS" "${POLARIS_MAKE_ARGS[@]}" 2>&1 | tee "$log_file"
    POLARIS_KERNEL_IMAGE="$POLARIS_OUT_DIR/arch/arm64/boot/Image.gz-dtb"
    [[ -s "$POLARIS_KERNEL_IMAGE" ]] || polaris_die "kernel image was not produced"
    printf 'kernel: %s\n' "$POLARIS_KERNEL_IMAGE"
    printf 'log: %s\n' "$log_file"
}

polaris_repack_boot() {
    local unpacker="$POLARIS_MKBOOTIMG_DIR/unpack_bootimg.py"
    local packer="$POLARIS_MKBOOTIMG_DIR/mkbootimg.py"
    local output_image="$POLARIS_OUTPUT_DIR/polaris-$POLARIS_VARIANT-$POLARIS_BUILD_ID.img"
    local kernel_copy="$POLARIS_OUTPUT_DIR/polaris-$POLARIS_VARIANT-$POLARIS_BUILD_ID-Image.gz-dtb"
    local repack_root
    local base_dir
    local verify_dir
    local args_file
    local kernel_replaced=0
    local index
    local -a mkbootimg_args=()

    repack_root=$(mktemp -d "$TMPDIR/polaris-repack.XXXXXX")
    base_dir="$repack_root/base"
    verify_dir="$repack_root/verify"
    args_file="$repack_root/mkbootimg.args"
    mkdir -p "$base_dir" "$verify_dir"

    python3 "$unpacker" --boot_img "$POLARIS_BOOT_IMAGE" --out "$base_dir" --format=mkbootimg -0 > "$args_file"
    mapfile -d '' -t mkbootimg_args < "$args_file"

    for ((index = 0; index < ${#mkbootimg_args[@]}; index++)); do
        if [[ "${mkbootimg_args[index]}" == --kernel ]]; then
            ((index + 1 < ${#mkbootimg_args[@]})) || polaris_die "invalid mkbootimg kernel argument"
            mkbootimg_args[index + 1]=$POLARIS_KERNEL_IMAGE
            kernel_replaced=1
            break
        fi
    done

    ((kernel_replaced)) || polaris_die "base boot image has no kernel argument"
    python3 "$packer" "${mkbootimg_args[@]}" --output "$output_image"
    python3 "$unpacker" --boot_img "$output_image" --out "$verify_dir" > "$repack_root/output.info"

    cmp -s "$verify_dir/kernel" "$POLARIS_KERNEL_IMAGE" || polaris_die "repacked kernel verification failed"
    cmp -s "$verify_dir/ramdisk" "$base_dir/ramdisk" || polaris_die "base ramdisk was not preserved"
    cp -- "$POLARIS_KERNEL_IMAGE" "$kernel_copy"
    sha256sum "$POLARIS_BOOT_IMAGE" "$output_image" | tee "$output_image.sha256"
    rm -rf -- "$repack_root"
    printf 'boot image: %s\n' "$output_image"
}
