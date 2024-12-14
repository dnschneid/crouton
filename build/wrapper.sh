 #!/bin/sh -e
# Copyright (c) 2016 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license.

# Wrapper script to untar itself, extract contents, and execute installer scripts.

set -e

# Constants
VERSION='git'
CROS_MIN_VERS=7262  # Minimum Chromium OS version
TEMP_DIR_BASE='/tmp'
BUNDLE_END_MARKER='###'
TAR_PARAMS=''

usage_extract() {
    echo "USAGE: ${0##*/} -x [directory]"
    echo "Extracts the contents of the tarball to the specified directory."
}

usage_run_script() {
    echo "USAGE: ${0##*/} -X DIR/SCRIPT [ARGS]"
    echo "Runs a script directly from the bundle. Valid DIR/SCRIPT combos:" 1>&2
    ls "$SCRIPTDIR/chroot-bin"/* "$SCRIPTDIR/host-bin"/* 1>&2
}

create_temp_dir() {
    local base_dir="$1"
    local prefix="${2:-wrapper}"
    mktemp -d --tmpdir="$base_dir" "${prefix}.XXX"
}

extract_bundle() {
    local script_path="$1"
    local dest_dir="$2"
    local start_line

    start_line=$(awk "/^$BUNDLE_END_MARKER/ { print FNR + 1; exit }" "$script_path")
    tail -n "+$start_line" "$script_path" | tar -x $TAR_PARAMS -C "$dest_dir"
}

cleanup() {
    [ -n "$TEMP_DIR" ] && rm -rf --one-file-system "$TEMP_DIR"
}

execute_script() {
    local script_path="$1"
    shift
    local options="-e"

    # Pass through shell options if the wrapper script was called with them
    [ "$(set -o | grep '^xtrace.*on$')" ] && options="$options -x"
    [ "$(set -o | grep '^verbose.*on$')" ] && options="$options -v"

    sh $options "$script_path" "$@"
}

main() {
    # Handle arguments
    if [ "$1" = '-x' ]; then
        if [ "$#" -gt 2 ]; then
            usage_extract
            exit 1
        fi
        DEST_DIR="${2:-${0##*/}.unbundled}"
        mkdir -p "$DEST_DIR"
        extract_bundle "$0" "$DEST_DIR"
        exit 0
    fi

    if [ "$1" = '-X' ]; then
        if [ "$#" -lt 2 ]; then
            usage_run_script
            exit 1
        fi
        TEMP_DIR=$(create_temp_dir "$TEMP_DIR_BASE" "${0##*/}")
        trap cleanup EXIT
        extract_bundle "$0" "$TEMP_DIR"
        SCRIPT_PATH="$TEMP_DIR/$2"
        if [ ! -f "$SCRIPT_PATH" ]; then
            usage_run_script
            exit 2
        fi
        shift 2
        execute_script "$SCRIPT_PATH" "$@"
        exit $?
    fi

    # Default behavior: extract and run `installer/main.sh`
    TEMP_DIR=$(create_temp_dir "$TEMP_DIR_BASE" "${0##*/}")
    trap cleanup EXIT
    extract_bundle "$0" "$TEMP_DIR"
    . "$TEMP_DIR/installer/main.sh"
}

main "$@"

exit 0
### end of script; tarball follows
