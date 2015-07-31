#!/bin/sh -e
# Copyright (c) 2015 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

USAGE="${0##*/} -a|-r /path/to/chroot

Detects the release (-r) or arch (-a) of the chroot and prints it on stdout.
Fails with an error code of 1 if the chroot does not belong to this distro."

if [ "$#" != 2 ] || [ "$1" != '-a' -a "$1" != '-r' ]; then
    echo "$USAGE" 1>&2
    exit 2
fi

sources="${2%/}/etc/apt/sources.list"
if [ ! -s "$sources" ]; then
    exit 1
fi

# Lookup the release name from the field after the URI
# We identify URI by '://'
rel="`sed -n 's|^deb .*://[^ ]* \([^ ]*\) main\( .*\)\?$|\1|p' \
    "$sources" "$sources.d"/*.list 2>/dev/null | head -n 1`"
if [ -z "$rel" ] || \
        ! grep -q "^$rel\([^a-z].*\)*$" "`dirname "$0"`/releases"; then
    exit 1
fi

# Print the architecture if requested
if [ "$1" = '-a' ]; then
    awk '/^Package: dpkg$/ {ok=1} ok && /^Architecture: / {print $2; exit}' \
        "${2%/}/var/lib/dpkg/status"
else
    echo "$rel"
fi

exit 0
