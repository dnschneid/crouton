#!/bin/sh -e
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Usage: prepare.sh arch mirror release
ARCH="${1:-"#ARCH"}"
MIRROR="${2:-"#MIRROR"}"
RELEASE="${3:-"#RELEASE"}"

# We need all paths to do administrative things
export PATH='/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin'

# Run debootstrap second stage if it hasn't already happened
if [ -r /debootstrap ]; then
    # Debootstrap doesn't like anything mounted under /sys when it runs
    # We assume that the chroot will be unmounted after this script is over, so
    # we don't need to explicitly remount anything. We also can't detect the
    # mounts properly due to the chroot, so we have to hardcode the mounts.
    umount '/sys/fs/fuse/connections'
    # Start the bootstrap
    /debootstrap/debootstrap --second-stage
    # Our custom /etc/resolv.conf link gets clobbered after bootstrap; fix it
    ln -sf host-shill/resolv.conf /etc/resolv.conf
fi

# The rest is dictated by the selected targets.
# Note that we install targets before adding the user, since targets may affect
# /etc/skel or other default parts. The user is added in post-common, which is
# always added to targets.
