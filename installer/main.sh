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

ARCH="`uname -m | sed -e 's/x86_64/amd64/' -e 's/arm.*/arm/'`"
DOWNLOADONLY=''
MIRROR='http://archive.ubuntu.com/ubuntu/'
NAME=''
PREFIX='/usr/local'
RELEASE='precise'
SSH='ssh'
TARBALL=''
TARGETS='help'
USERNAME=''

USAGE="$APPLICATION [options] -t targets [user@]host
$APPLICATION [options] -f tarball

Constructs a Debian-based chroot for running alongside Chromium OS.

If run without -f, a hostname of a Debian/Ubuntu machine must be specified in
order to bootstrap. You do not need root on the remote machine unless
debootstrap is not installed, in which case you will need to either have root to
install it or manually install it yourself.

If run with -f, a tarball is used to bootstrap the chroot. If specified with -d,
the tarball is created (either via a remote machine or a local copy of
debootstrap) for later use with -f.

Options:
    -a ARCH     The architecture to prepare the chroot for. Default: $ARCH
    -d          Downloads the bootstrap tarball but does not prepare the chroot.
    -f TARBALL  The tarball to use, or download to in the case of -d.
                When using a prebuilt tarball, -a and -r are ignored.
    -m MIRROR   Mirror to use for apt-get. Default: $MIRROR
    -n NAME     Name of the chroot. Default is the release name.
    -p PREFIX   The root directory in which to install the bin and chroot
                subdirectories and data. Default: $PREFIX
    -r RELEASE  Name of the distribution release. Default: $RELEASE
    -s SSH      SSH command to use. Default: $SSH
    -t TARGETS  Comma-separated list of environment targets to install.
                Specify help (or omit) to print out potential targets.
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
    s) SSH="$OPTARG";;
    t) TARGETS="$OPTARG";;
    u) USERNAME="$OPTARG";;
    \?) error 2 "$USAGE";;
    esac
done
shift "$((OPTIND-1))"

# If a tarball isn't specified, we need ssh parameters
if [ $# = 0 -a -z "$TARBALL" ]; then
    error 2 "$USAGE"
fi

# It's invalid to specify tarball and ssh parameters but not -d
if [ -z "$DOWNLOADONLY" -a -n "$TARBALL" -a ! $# = 0 ]; then
    error 2 "$USAGE"
fi

# Confirm or list targets if requested (and download only isn't chosen)
if [ -z "$DOWNLOADONLY" ]; then
    t="${TARGETS%,},"
    while [ -n "$t" ]; do
        TARGET="${t%%,*}"
        t="${t#*,}"
        if [ "$TARGET" = 'help' ]; then
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

# We need to run as root if we're actually installing
if [ -z "$DOWNLOADONLY" ]; then
    if [ ! "$USER" = root -a ! "$UID" = 0 ]; then
        error 2 "$APPLICATION must be run as root."
    fi
# If we are only downloading, we need a destination tarball
elif [ -z "$TARBALL" ]; then
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
    mkdir -p "$BIN" "$CHROOT"/usr/local/bin
fi

# Prepare to download the tarball (or grab it locally)
rmtarball=''
if [ -z "$DOWNLOADONLY" ]; then
    echo "Installing $RELEASE-$ARCH chroot to $CHROOT" 1>&2
    if [ -z "$TARBALL" ]; then
        TARBALL="`mktemp --tmpdir=/tmp install-chroot.XXX`"
        rmtarball="rm -f \"$TARBALL\""
        TRAP="$rmtarball; $TRAP"
        trap "$TRAP" INT HUP 0
    fi
else
    echo "Downloading $RELEASE to $TARBALL" 1>&2
    if [ $# = 0 ]; then
        . "$INSTALLERDIR/download.sh"
        exit
    fi
fi

# Grab the tarball over ssh if we need it
if [ ! $# = 0 ]; then
    echo "Bootstrapping using $SSH $*" 1>&2
    # If we have to install debootstrap, we'll be passing the password over
    # STDIN. Make sure we won't be exposing it on the terminal.
    stty -echo 2>/dev/null || true
    $SSH "$@" sh -ec \'"`cat "$INSTALLERDIR/download.sh"`"\' \
        download-chroot \'"$RELEASE"\' \'"$ARCH"\' \'"$MIRROR"\' \
        - > "$TARBALL"
    # Vim's syntax highlighting really has troubles with the above...
    stty echo 2>/dev/null || true
    # If we're just downloading, we're done!
    if [ -n "$DOWNLOADONLY" ]; then
        exit
    fi
fi

# Unpack the chroot
echo 'Unpacking chroot environment...' 1>&2
tar -C "$CHROOT" --strip-components=1 -xf "$TARBALL"
# We're done with the tarball, so remove it if it's temporary
eval "$rmtarball"

# Create the setup script inside the chroot
echo 'Preparing chroot environment...' 1>&2
VAREXPAND="s #ARCH $ARCH ;s #MIRROR $MIRROR ;
           s #RELEASE $RELEASE ;s #USERNAME $USERNAME ;"
sed -e "$VAREXPAND" "$INSTALLERDIR/prepare.sh" > "$CHROOT/prepare.sh"
# Create a file for target deduplication
TARGETDEDUPFILE="`mktemp --tmpdir=/tmp prepare-chroot.XXX`"
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
