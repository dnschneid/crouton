#!/bin/sh -e
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

APPLICATION="${0##*/}"
SCRIPTDIR="${SCRIPTDIR:-"`dirname "$0"`/.."}"
CHROOTBINDIR="$SCRIPTDIR/chroot-bin"
INSTALLERDIR="$SCRIPTDIR/installer"
HOSTBINDIR="$SCRIPTDIR/host-bin"
TARGETSDIR="$SCRIPTDIR/targets"

ARCH="`uname -m | sed -e 's/x86_64/amd64/' -e 's/arm.*/armhf/'`"
DOWNLOADONLY=''
MIRROR=''
MIRROR86='http://archive.ubuntu.com/ubuntu/'
MIRRORARM='http://ports.ubuntu.com/ubuntu-ports/'
NAME=''
PREFIX='/usr/local'
RELEASE='precise'
TARBALL=''
TARGETS=''
USERNAME=''

USAGE="$APPLICATION [options] -t targets
$APPLICATION [options] -d -f tarball

Constructs a Debian-based chroot for running alongside Chromium OS.

If run with -f, a tarball is used to bootstrap the chroot. If specified with -d,
the tarball is created for later use with -f.

This must be run as root unless -d is specified AND fakeroot is installed AND
/tmp is mounted exec and dev.

Options:
    -a ARCH     The architecture to prepare the chroot for. Default: $ARCH
    -d          Downloads the bootstrap tarball but does not prepare the chroot.
    -f TARBALL  The tarball to use, or download to in the case of -d.
                When using a prebuilt tarball, -a and -r are ignored.
    -m MIRROR   Mirror to use for bootstrapping and apt-get.
                Default for i386/amd64: $MIRROR86
                Default for armhl/others: $MIRRORARM
    -n NAME     Name of the chroot. Default is the release name.
    -p PREFIX   The root directory in which to install the bin and chroot
                subdirectories and data. Default: $PREFIX
    -r RELEASE  Name of the distribution release. Default: $RELEASE
    -t TARGETS  Comma-separated list of environment targets to install.
                Specify help to print out potential targets.
    -u USERNAME Username of the primary user to add to the chroot.
                If unspecified, you will be asked for it later.

Be aware that dev mode is inherently insecure, even if you have a strong
password in your chroot! Anyone can simply switch VTs and gain root access
unless you've permanently assigned a ChromiumOS root password."

# Function to exit with exit code $1, spitting out message $@ to stderr
error() {
    local ecode="$1"
    shift
    echo "$*" 1>&2
    exit "$ecode"
}

# Process arguments
while getopts 'a:df:m:n:p:r:s:t:u:' f; do
    case "$f" in
    a) ARCH="$OPTARG";;
    d) DOWNLOADONLY='y';;
    f) TARBALL="$OPTARG";;
    m) MIRROR="$OPTARG";;
    n) NAME="$OPTARG";;
    p) PREFIX="$OPTARG";;
    r) RELEASE="$OPTARG";;
    t) TARGETS="$OPTARG";;
    u) USERNAME="$OPTARG";;
    \?) error 2 "$USAGE";;
    esac
done
shift "$((OPTIND-1))"

# If targets weren't specified, we should just print help text.
if [ -z "$DOWNLOADONLY" -a -z "$TARGETS" ]; then
    error 2 "$USAGE"
fi

# There should never be any extra parameters.
if [ ! $# = 0 ]; then
    error 2 "$USAGE"
fi

# If MIRROR wasn't specified, choose it based on ARCH.
if [ -z "$MIRROR" ]; then
    if [ "$ARCH" = 'amd64' -o "$ARCH" = 'i386' ]; then
        MIRROR="$MIRROR86"
    else
        MIRROR="$MIRRORARM"
    fi
fi

# Confirm or list targets if requested (and download only isn't chosen)
if [ -z "$DOWNLOADONLY" ]; then
    t="${TARGETS%,},"
    while [ -n "$t" ]; do
        TARGET="${t%%,*}"
        t="${t#*,}"
        if [ "$TARGET" = 'help' -o "$TARGET" = 'list' ]; then
            TARGETS='help'
            echo "Available targets:" 1>&2
            for t in "$TARGETSDIR/"*; do
                TARGET="${t##*/}"
                if [ "${TARGET%common}" = "$TARGET" ]; then
                    (. "$t") 1>&2
                fi
            done
            exit 2
        elif [ ! "${TARGET%common}" = "$TARGET" ] || \
             [ ! -r "$TARGETSDIR/$TARGET" ]; then
            error 2 "Invalid target \"$TARGET\"."
        fi
    done
fi

# If we're not running as root, we must be downloading and have fakeroot and
# have an exec and dev /tmp
if grep -q '.* /tmp .*\(nodev\|noexec\)' /proc/mounts; then
    NOEXECTMP=y
else
    NOEXECTMP=n
fi
FAKEROOT=''
if [ ! "$USER" = root -a ! "$UID" = 0 ]; then
    FAKEROOT=fakeroot
    if [ "$NOEXECTMP" = y -o -z "$DOWNLOADONLY" ] \
            || ! hash "$FAKEROOT" 2>/dev/null; then
        error 2 "$APPLICATION must be run as root."
    fi
fi

# If we are only downloading, we need a destination tarball
if [ -n "$DOWNLOADONLY" -a -z "$TARBALL" ]; then
    error 2 "$USAGE"
fi

# If we specified a tarball, we need to detect the ARCH and RELEASE
if [ -z "$DOWNLOADONLY" -a -n "$TARBALL" ]; then
    if [ ! -f "$TARBALL" ]; then
        error 2 "$TARBALL not found."
    fi
    echo 'Detecting archive release and architecture...' 1>&2
    releasearch="`tar -tf "$TARBALL" 2>/dev/null | head -n 1`"
    ARCH="${releasearch#*-}"
    ARCH="${ARCH%/}"
    RELEASE="${releasearch%-*}"
fi

# Done with parameter processing!
# Make sure we always have echo when this script exits
TRAP="stty echo 2>/dev/null || true; $TRAP"
trap "$TRAP" INT HUP 0

# Deterime directories
BIN="$PREFIX/bin"
CHROOTS="$PREFIX/chroots"
CHROOT="$CHROOTS/${NAME:-"$RELEASE"}"

# Confirm we have write access to the directory before starting.
if [ -z "$DOWNLOADONLY" ]; then
    if [ -d "$CHROOT" ] && ! rmdir "$CHROOT" 2>/dev/null; then
        error 1 "$CHROOT already has stuff in it!
Either delete it or specify a different name (-n)."
    fi
    mkdir -p "$BIN" "$CHROOT"
fi

# Unpack the tarball if appropriate
if [ -z "$DOWNLOADONLY" ]; then
    echo "Installing $RELEASE-$ARCH chroot to $CHROOT" 1>&2
    if [ -n "$TARBALL" ]; then
        # Unpack the chroot
        echo 'Unpacking chroot environment...' 1>&2
        tar -C "$CHROOT" --strip-components=1 -xf "$TARBALL"
    fi
else
    echo "Downloading $RELEASE-$ARCH bootstrap to $TARBALL" 1>&2
fi

# Download the bootstrap data if appropriate
if [ -n "$DOWNLOADONLY" -o -z "$TARBALL" ]; then
    # Ensure that /tmp is mounted exec and dev
    if [ "$NOEXECTMP" = 'y' ]; then
        echo 'Remounting /tmp with dev+exec...' 1>&2
        mount -o remount,dev,exec /tmp
    fi

    # Create the temporary directory and delete it upon exit
    tmp="`mktemp -d --tmpdir=/tmp "$APPLICATION.XXX"`"
    subdir="$RELEASE-$ARCH"
    TRAP="rm -rf \"$tmp\"; $TRAP"
    trap "$TRAP" INT HUP 0

    # Grab the latest release of debootstrap
    echo 'Downloading debootstrap...' 1>&2
    wget 'http://anonscm.debian.org/gitweb/?p=d-i/debootstrap.git;a=snapshot;h=HEAD;sf=tgz' \
        -qO- | tar -C "$tmp" --strip-components=1 -zx

    # Add the necessary debootstrap executables
    newpath="$PATH:$tmp"
    cp "$INSTALLERDIR/ar" "$INSTALLERDIR/pkgdetails" "$tmp/"
    chmod 755 "$INSTALLERDIR/ar" "$INSTALLERDIR/pkgdetails" 

    # debootstrap wants a file to initialize /dev with, but we don't actually
    # want any files there. Create an empty tarball that it can extract.
    tar -czf "$tmp/devices.tar.gz" -T /dev/null

    # Grab the release and drop it into the subdirectory
    echo 'Downloading bootstrap files...' 1>&2
    PATH="$newpath" DEBOOTSTRAP_DIR="$tmp" $FAKEROOT \
        "$tmp/debootstrap" --foreign --arch="$ARCH" "$RELEASE" \
                           "$tmp/$subdir" "$MIRROR" 1>&2

    # Tar it up if we're only downloading
    if [ -n "$DOWNLOADONLY" ]; then
        echo 'Compressing bootstrap files...' 1>&2
        $FAKEROOT tar -C "$tmp" -cajf "$TARBALL" "$subdir"
        echo 'Done!' 1>&2
        exit 0
    fi

    # Move it to the right place
    echo 'Moving bootstrap files into the chroot...' 1>&2
    mv -f "$tmp/$subdir/"* "$CHROOT"
fi

# Ensure that /usr/local/bin exists
mkdir -p "$CHROOT/usr/local/bin"

# Create the setup script inside the chroot
echo 'Preparing chroot environment...' 1>&2
VAREXPAND="s #ARCH $ARCH ;s #MIRROR $MIRROR ;
           s #RELEASE $RELEASE ;s #USERNAME $USERNAME ;"
sed -e "$VAREXPAND" "$INSTALLERDIR/prepare.sh" > "$CHROOT/prepare.sh"
# Create a file for target deduplication
TARGETDEDUPFILE="`mktemp --tmpdir=/tmp "$APPLICATION.XXX"`"
rmtargetdedupfile="rm -f \"$TARGETDEDUPFILE\""
TRAP="$rmtargetdedupfile; $TRAP"
trap "$TRAP" INT HUP 0
# Run each target, appending stdout to the prepare script.
t="${TARGETS%,},post-common,"
while [ -n "$t" ]; do
    TARGET="${t%%,*}"
    t="${t#*,}"
    (. "$TARGETSDIR/$TARGET") >> "$CHROOT/prepare.sh"
done
chmod 500 "$CHROOT/prepare.sh"
# Delete the temp file
eval "$rmtargetdedupfile"

# Run the setup script inside the chroot
sh -e "$HOSTBINDIR/enter-chroot" -c "$CHROOTS" -n "$NAME" -x '/prepare.sh'

echo "Done! You can enter the chroot using enter-chroot." 1>&2
