#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Usage: prepare.sh arch mirror release proxy version
ARCH="${1:-"#ARCH"}"
MIRROR="${2:-"#MIRROR"}"
RELEASE="${3:-"#RELEASE"}"
PROXY="${4:-"#PROXY"}"
VERSION="${5:-"#VERSION"}"

# noauto: For the specified packages, echos out "pkg-" for each package in the
# list that isn't already installed. Targets use this to avoid installing
# packages that really aren't needed, or should have been covered by prereq
# targets; e.g. apt-get install xfce4 `noauto xorg`
noauto() {
    for pkg in "$@"; do
        if ! dpkg-query -s "$pkg" 2>/dev/null >/dev/null; then
            echo -n "$pkg- "
        fi
    done
}

# compile: Grabs the necessary dependencies and then compiles a C file from
# stdin to the specified output and strips it. Finally, removes whatever it
# installed. This allows targets to provide on-demand binaries without
# increasing the size of the chroot after install.
# $1: name; target is /usr/local/bin/crouton$1
# $2: linker flags, quoted together
# $3+: any package dependencies other than gcc and libc-dev.
compile() {
    local out="/usr/local/bin/crouton$1" linker="$2"
    echo "Installing dependencies for $out..." 1>&2
    shift 2
    local pkgs="gcc libc-dev $*"
    local remove="`noauto $pkgs`"
    apt-get -y --no-install-recommends install $pkgs
    echo "Compiling $out..." 1>&2
    ret=0
    if ! gcc -xc -Os - $linker -o "$out" || ! strip "$out"; then
        ret=1
    fi
    apt-get -y --purge autoremove $remove
    return $ret
}

# We need all paths to do administrative things
export PATH='/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin'

# Apply the proxy for this script
if [ ! "$PROXY" = 'unspecified' -a "${PROXY#"#"}" = "$PROXY" ]; then
    export http_proxy="$PROXY" https_proxy="$PROXY" ftp_proxy="$PROXY"
fi

# Run debootstrap second stage if it hasn't already happened
if [ -r /debootstrap ]; then
    # Debootstrap doesn't like anything mounted under /sys or /var when it runs
    # We assume that the chroot will be unmounted after this script is over, so
    # we don't need to explicitly remount anything. We also can't detect the
    # mounts properly due to the chroot, so we have to hardcode the mounts.
    umount '/sys/fs/fuse/connections' '/var/run/lock' '/var/run'
    # Our custom /etc/resolv.conf link gets clobbered after bootstrap; save it
    mv -f /etc/resolv.conf /etc/resolv.conf.save
    # Start the bootstrap
    /debootstrap/debootstrap --second-stage
    # Fix the /etc/resolv.conf
    mv -f /etc/resolv.conf.save /etc/resolv.conf
    # Fix the tty keyboard mode. keyboard-configuration puts tty1~6 in UTF8
    # mode, assuming they are consoles. Since everything other than tty2 can be
    # an X11 session, we need to revert those back to RAW.
    for tty in 1 3 4 5 6; do
        kbd_mode -s -C "/dev/tty$tty"
    done
fi

# The rest is dictated by the selected targets.
# Note that we install targets before adding the user, since targets may affect
# /etc/skel or other default parts. The user is added in post-common, which is
# always added to targets.
