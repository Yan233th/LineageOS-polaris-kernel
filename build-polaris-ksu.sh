#!/usr/bin/env bash
set -euo pipefail

export POLARIS_VARIANT=ksu
SCRIPT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=build-polaris-common.sh
source "$SCRIPT_ROOT/build-polaris-common.sh"

KERNELSU_REPOSITORY=${POLARIS_KERNELSU_REPOSITORY:-https://github.com/tiann/KernelSU.git}
KERNELSU_TAG=v0.9.5
KERNELSU_COMMIT=b766b98513b5a7eb33bc1c4a76b5702bf1288f07
KSU_WORKTREE=""
KSU_WORKTREE_ROOT=""

cleanup_ksu_worktree() {
    if [[ -n "$KSU_WORKTREE" && -e "$KSU_WORKTREE/.git" ]]; then
        git -C "$SCRIPT_ROOT" worktree remove --force "$KSU_WORKTREE"
        KSU_WORKTREE=""
    fi
    if [[ -n "$KSU_WORKTREE_ROOT" ]]; then
        rmdir "$KSU_WORKTREE_ROOT" 2>/dev/null || true
    fi
}

trap cleanup_ksu_worktree EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

polaris_parse_args "$@"
polaris_require_tracked_clean "$SCRIPT_ROOT"

KSU_WORKTREE_ROOT=${POLARIS_KSU_WORKTREE_ROOT:-"$POLARIS_KERNEL_BUILD_ROOT/polaris-ksu-worktrees"}
mkdir -p "$KSU_WORKTREE_ROOT"
KSU_WORKTREE="$KSU_WORKTREE_ROOT/$POLARIS_BUILD_ID-$$"
git -C "$SCRIPT_ROOT" worktree add --detach "$KSU_WORKTREE" HEAD

git clone --depth 1 --branch "$KERNELSU_TAG" --single-branch "$KERNELSU_REPOSITORY" "$KSU_WORKTREE/KernelSU"
[[ "$(git -C "$KSU_WORKTREE/KernelSU" rev-parse HEAD)" == "$KERNELSU_COMMIT" ]] || polaris_die "unexpected KernelSU commit"

[[ ! -e "$KSU_WORKTREE/drivers/kernelsu" ]] || polaris_die "drivers/kernelsu already exists"
[[ "$(tail -n 1 "$KSU_WORKTREE/drivers/Kconfig")" == endmenu ]] || polaris_die "unexpected drivers/Kconfig layout"
ln -s ../KernelSU/kernel "$KSU_WORKTREE/drivers/kernelsu"
sed -i '$i source "drivers/kernelsu/Kconfig"' "$KSU_WORKTREE/drivers/Kconfig"
printf '\nobj-%s += kernelsu/\n' "\$(CONFIG_KSU)" >> "$KSU_WORKTREE/drivers/Makefile"

polaris_prepare_environment
polaris_build_kernel "$KSU_WORKTREE" "$SCRIPT_ROOT/build/polaris/kernelsu.config"

if ((POLARIS_CONFIG_ONLY == 0)); then
    polaris_repack_boot
fi
