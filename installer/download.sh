#!/bin/sh -e
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This file is passed through SSH+sh, so DO NOT USE ANY SINGLE QUOTES.

# Usage:
# download.sh release arch mirror tarball
RELEASE="${1:-"$RELEASE"}"
ARCH="${2:-"$ARCH"}"
MIRROR="${3:-"$MIRROR"}"
TARBALL="${4:-"$TARBALL"}"

# Make the tarball path absolute (unless it is -, which means stdout)
if [ "${TARBALL:-"-"}" = "-" ]; then
    TARBALL="/dev/stdout"
elif [ "${TARBALL#/}" = "$TARBALL" ]; then
    TARBALL="$PWD/$TARBALL";
fi

# Tarball will have a root directory
dir="$RELEASE-$ARCH"

# debootstrap often lives in /usr/sbin
if [ "${PATH#*sbin}" = "$PATH" ]; then
    export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
fi

needsinstall=""
# Check if we have debootstrap and fakeroot
hash debootstrap || needsinstall="$needsinstall debootstrap"
hash fakeroot || needsinstall="$needsinstall fakeroot"
if [ -n "$needsinstall" ]; then
    echo "The following packages need to be installed:$needsinstall" 1>&2
    SUDOPARAMS=""
    # If we do not have a tty, we need to grab the password over STDIN
    tty -s || SUDOPARAMS="-S"
    sudo $SUDOPARAMS apt-get -y install $needsinstall 1>&2
fi

# Create the temporary directory and delete it upon exit
tmp="`mktemp -d --tmpdir=/tmp download-chroot.XXX`"
trap "rm -rf \"$tmp\"" INT HUP 0

# Enter the directory
cd "$tmp"

# Grab the release and drop it into the subdirectory. No code is executed.
fakeroot debootstrap --foreign --arch="$ARCH" "$RELEASE" "$dir" "$MIRROR" 1>&2

# Tar it up!
echo -n "Compressing and downloading chroot environment..." 1>&2
fakeroot tar --checkpoint=100 --checkpoint-action=exec="echo -n . 1>&2" \
             -cajf "$TARBALL" "$dir"
echo "done" 1>&2
