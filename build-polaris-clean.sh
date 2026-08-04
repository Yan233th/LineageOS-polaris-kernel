#!/usr/bin/env bash
set -euo pipefail

export POLARIS_VARIANT=clean
SCRIPT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=build-polaris-common.sh
source "$SCRIPT_ROOT/build-polaris-common.sh"

polaris_parse_args "$@"
polaris_require_tracked_clean "$SCRIPT_ROOT"
polaris_prepare_environment
polaris_build_kernel "$SCRIPT_ROOT"

if ((POLARIS_CONFIG_ONLY == 0)); then
    polaris_repack_boot
fi
