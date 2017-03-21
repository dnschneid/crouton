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

# Check if this is gentoo
if [ -f "${2%/}/etc/gentoo-release" ]; then
    # Print the architecture if requested
    if [ "$1" = '-a' ]; then
        echo `readlink "${2%/}/etc/portage/make.profile" | cut -d"/" -f8`
    else
    	echo "gentoo"
    fi
    exit 0
else
    exit 1
fi
