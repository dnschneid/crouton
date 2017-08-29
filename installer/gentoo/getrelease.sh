#!/bin/sh -e
# Copyright (c) 2017 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

USAGE="${0##*/} -a|-r /path/to/chroot

Detects the release (-r) or arch (-a) of the chroot and prints it on stdout.
Fails with an error code of 1 if the chroot does not belong to this distro."

if [ "$#" != 2 ] || [ "$1" != '-a' -a "$1" != '-r' ]; then
    echo "$USAGE" 1>&2
    exit 2
fi

# Check if this is gentoo by looking for the lsb release file
if [ ! -f "${2%/}/etc/gentoo-release" ]; then
    exit 1
fi

# Get the architecture from the CHOST
if [ "$1" = '-a' ]; then
    PM="/etc/portage/make.conf"
    # Get the CHOST architecture, first part of the tuple
    CHOST="$(sed -n -e 's/^CHOST="\(.*\)*"/\1/p' "${2%/}$PM" | cut -d- -f1)"

    case "$CHOST" in
    x86_64) echo "amd64";;
    i?86) echo "x86";;
    aarch64) echo "arm64";;
    arm*) echo "arm";;
    *) echo "Invalid architecture '$ARCH'."; exit 2;;
    esac
else
    echo "gentoo"
fi
exit 0
