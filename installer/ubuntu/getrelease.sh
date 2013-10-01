#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

USAGE="${0##*/} -a|-r /path/to/chroot

Detects the release (-r) or arch (-a) of the chroot and prints it on stdout.
Fails with an error code of 1 if the chroot does not belong to this distro.
Returns 'incompatible' for the arch if it cannot be run on this system."

if [ "$#" != 2 ] || [ "$1" != '-a' -a "$1" != '-r' ]; then
    echo "$USAGE" 1>&2
    exit 2
fi

sources="${2%/}/etc/apt/sources.list"
if [ ! -s "$sources" ]; then
    exit 1
fi

rel="`awk '/^deb .* main( .*)?$/ { print $3; exit }' \
          "$sources" "$sources.d"/*.list 2>/dev/null`"
if [ -z "$rel" ] || ! grep -q "^$rel[^a-z]*$" "`dirname "$0"`/releases"; then
    exit 1
fi

# Print the architecture if requested
if [ "$1" = '-a' ]; then
    if ! env -i chroot "$2" su -s '/bin/sh' \
            -c 'dpkg --print-architecture' - root 2>/dev/null; then
        echo 'incompatible'
    fi
    exit 0
fi

echo "$rel"
exit 0
