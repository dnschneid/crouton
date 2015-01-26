#!/bin/sh -e
# Copyright (c) 2014 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file of the source repository, which has been replicated
# below for convenience of distribution:
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
#    * Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
#    * Redistributions in binary form must reproduce the above
# copyright notice, this list of conditions and the following disclaimer
# in the documentation and/or other materials provided with the
# distribution.
#    * Neither the name of Google Inc. nor the names of its
# contributors may be used to endorse or promote products derived from
# this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# This is a wrapped tarball. This script untars itself to a temporary directory
# and then runs installer/main.sh with the parameters passed to it.
# You can pass -x [directory] to extract the contents somewhere.

set -e

VERSION='git'

# Minimum Chromium OS version is R35 stable
CROS_MIN_VERS=5712

if [ "$1" = '-x' -a "$#" -le 2 ]; then
    # Extract to the specified directory.
    SCRIPTDIR="${2:-"${0##*/}.unbundled"}"
    mkdir -p "$SCRIPTDIR"
else
    # Make a temporary directory and auto-remove it when the script ends.
    SCRIPTDIR="`mktemp -d --tmpdir=/tmp "${0##*/}.XXX"`"
    TRAP="rm -rf --one-file-system '$SCRIPTDIR';$TRAP"
    trap "$TRAP" INT HUP 0
fi

# Extract this file after the ### line
# TARPARAMS will be set by the Makefile to match the compression method.
line="`awk '/^###/ { print FNR+1; exit 0; }' "$0"`"
tail -n "+$line" "$0" | tar -x $TARPARAMS -C "$SCRIPTDIR"

# Exit here if we're just extracting
if [ -z "$TRAP" ]; then
    exit
fi

# See if we want to just run a script from the bundle
if [ "$1" = '-X' ]; then
    script="$SCRIPTDIR/$2"
    if [ ! -f "$script" ]; then
        cd "$SCRIPTDIR"
        echo "USAGE: ${0##*/} -X DIR/SCRIPT [ARGS]
Runs a script directly from the bundle. Valid DIR/SCRIPT combos:" 1>&2
        ls chroot-bin/* host-bin/* 1>&2
        if [ -n "$2" ]; then
            echo 1>&2
            echo "Invalid script '$2'" 1>&2
        fi
        exit 2
    fi
    shift 2
    # If this script was called with '-x' or '-v', pass that on
    SETOPTIONS="-e"
    if set -o | grep -q '^xtrace.*on$'; then
        SETOPTIONS="$SETOPTIONS -x"
    fi
    if set -o | grep -q '^verbose.*on$'; then
        SETOPTIONS="$SETOPTIONS -v"
    fi
    sh $SETOPTIONS "$script" "$@"
    exit "$?"
fi

# Execute the main script inline. It will use SCRIPTDIR to find what it needs.
. "$SCRIPTDIR/installer/main.sh"

exit
### end of script; tarball follows
