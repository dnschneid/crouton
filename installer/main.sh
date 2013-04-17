#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

APPLICATION="${0##*/}"
SCRIPTDIR="${SCRIPTDIR:-"`dirname "$0"`/.."}"
CHROOTBINDIR="$SCRIPTDIR/chroot-bin"
CHROOTETCDIR="$SCRIPTDIR/chroot-etc"
INSTALLERDIR="$SCRIPTDIR/installer"
HOSTBINDIR="$SCRIPTDIR/host-bin"
TARGETSDIR="$SCRIPTDIR/targets"
SRCDIR="$SCRIPTDIR/src"

ARCH="`uname -m | sed -e 's i.86 i386 ;s x86_64 amd64 ;s arm.* armhf ;'`"
DOWNLOADONLY=''
ENCRYPT=''
KEYFILE=''
MIRROR=''
MIRROR86='http://archive.ubuntu.com/ubuntu/'
MIRRORARM='http://ports.ubuntu.com/ubuntu-ports/'
NAME=''
PREFIX='/usr/local'
PROXY='unspecified'
RELEASE='precise'
TARBALL=''
TARGETS=''
TARGETFILE=''
UPDATE=''

USAGE="$APPLICATION [options] -t targets
$APPLICATION [options] -d -f tarball

Constructs a Debian-based chroot for running alongside Chromium OS.

If run with -f, a tarball is used to bootstrap the chroot. If specified with -d,
the tarball is created for later use with -f.

This must be run as root unless -d is specified AND fakeroot is installed AND
/tmp is mounted exec and dev.

It is highly recommended to run this from a crosh shell (Ctrl+Alt+T), not VT2.

Options:
    -a ARCH     The architecture to prepare the chroot for. Default: $ARCH
    -d          Downloads the bootstrap tarball but does not prepare the chroot.
    -e          Encrypt the chroot with ecryptfs using a passphrase.
    -f TARBALL  The tarball to use, or download to in the case of -d.
                When using a prebuilt tarball, -a and -r are ignored.
    -k KEYFILE  File or directory to store the (encrypted) encryption keys in.
                If unspecified, the keys will be stored in the chroot if doing a
                first encryption, or auto-detected on existing chroots.
    -m MIRROR   Mirror to use for bootstrapping and apt-get.
                Default for i386/amd64: $MIRROR86
                Default for armhl/others: $MIRRORARM
    -n NAME     Name of the chroot. Default is the release name.
    -p PREFIX   The root directory in which to install the bin and chroot
                subdirectories and data. Default: $PREFIX
    -P PROXY    Set an HTTP proxy for the chroot; effectively sets http_proxy.
                Specify an empty string to remove a proxy when updating.
    -r RELEASE  Name of the distribution release. Default: $RELEASE
    -t TARGETS  Comma-separated list of environment targets to install.
                Specify help to print out potential targets.
    -T TARGETFILE  Path to a custom target definition file that gets applied to
                the chroot as if it were a target in the $APPLICATION bundle.
    -u          If the chroot exists, runs the preparation step again.
                You can use this to install new targets or update old ones.
    -V          Prints the version of the installer to stdout.

Be aware that dev mode is inherently insecure, even if you have a strong
password in your chroot! Anyone can simply switch VTs and gain root access
unless you've permanently assigned a Chromium OS root password. Encrypted
chroots require you to set a Chromium OS root password, but are still only as
secure as the passphrases you assign to them."

# Function to exit with exit code $1, spitting out message $@ to stderr
error() {
    local ecode="$1"
    shift
    echo "$*" 1>&2
    exit "$ecode"
}

# Process arguments
while getopts 'a:def:k:m:n:p:P:r:s:t:T:uV' f; do
    case "$f" in
    a) ARCH="$OPTARG";;
    d) DOWNLOADONLY='y';;
    e) ENCRYPT='-e';;
    f) TARBALL="$OPTARG";;
    k) KEYFILE="$OPTARG";;
    m) MIRROR="$OPTARG";;
    n) NAME="$OPTARG";;
    p) PREFIX="`readlink -f "$OPTARG"`";;
    P) PROXY="$OPTARG";;
    r) RELEASE="$OPTARG";;
    t) TARGETS="$TARGETS${TARGETS:+","}$OPTARG";;
    T) TARGETFILE="$OPTARG";;
    u) UPDATE='y';;
    V) echo "$APPLICATION: version ${VERSION:-"git"}"; exit 0;;
    \?) error 2 "$USAGE";;
    esac
done
shift "$((OPTIND-1))"

# If targets weren't specified, we should just print help text.
if [ -z "$DOWNLOADONLY" -a -z "$TARGETS" -a -z "$TARGETFILE" ]; then
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
        if [ -z "$TARGET" ]; then
            continue
        elif [ "$TARGET" = 'help' -o "$TARGET" = 'list' ]; then
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
             [ ! -r "$TARGETSDIR/$TARGET" ] || \
             ! (TARGETS='check'; . "$TARGETSDIR/$TARGET"); then
            error 2 "Invalid target \"$TARGET\"."
        fi
    done
    if [ -n "$TARGETFILE" ]; then
        if [ ! -r "$TARGETFILE" ]; then
            error 2 "Could not find \"$TARGETFILE\"."
        elif [ ! -f "$TARGETFILE" ]; then
            error 2 "\"$TARGETFILE\" is not a target definition file."
        fi
    fi
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

# Check if we're running from a tty, which does not interact well with X11
if [ -z "$DOWNLOADONLY" ] && \
        readlink -f "/proc/$$/fd/0" | grep -q '^/dev/tty'; then
    echo \
"WARNING: It is highly recommended that you run $APPLICATION from a crosh shell
(Ctrl+Alt+T in Chromium OS), not from a VT. If you continue to run this from a
VT, you're gonna have a bad time. Press Ctrl-C at any point to abort." 1>&2
    sleep 5
fi

# If we specified a tarball, we need to detect the ARCH and RELEASE
if [ -z "$DOWNLOADONLY" -a -n "$TARBALL" ]; then
    if [ ! -f "$TARBALL" ]; then
        error 2 "$TARBALL not found."
    fi
    echo 'Detecting archive release and architecture...' 1>&2
    releasearch="`tar -tf "$TARBALL" 2>/dev/null | head -n 1`"
    releasearch="${releasearch%%/*}"
    if [ ! "${releasearch#*-}" = "$releasearch" ]; then
        ARCH="${releasearch#*-}"
        RELEASE="${releasearch%-*}"
    else
        echo 'Unable to detect archive release and architecture. Using flags.' 1>&2
    fi
fi

# Set http_proxy if a proxy is specified.
if [ ! "$PROXY" = 'unspecified' ]; then
    export http_proxy="$PROXY" https_proxy="$PROXY" ftp_proxy="$PROXY"
fi

# Done with parameter processing!
# Make sure we always have echo when this script exits
TRAP="stty echo 2>/dev/null || true;$TRAP"
trap "$TRAP" INT HUP 0

# Deterime directories, and fix NAME if it was not specified.
BIN="$PREFIX/bin"
CHROOTS="$PREFIX/chroots"
CHROOT="$CHROOTS/${NAME:="$RELEASE"}"

# Confirm we have write access to the directory before starting.
NODOWNLOAD=''
if [ -z "$DOWNLOADONLY" ]; then
    create='-n'
    if [ -d "$CHROOT" ] && ! rmdir "$CHROOT" 2>/dev/null; then
        if [ -z "$UPDATE" ]; then
            error 1 "$CHROOT already has stuff in it!
Either delete it, specify a different name (-n), or specify -u to update it."
        fi
        NODOWNLOAD='y'
        create=''
        echo "$CHROOT already exists; updating it..." 1>&2
    elif [ -n "$UPDATE" ]; then
        error 1 "$CHROOT does not exist; cannot update."
    fi

    # Mount the chroot and update CHROOT path
    if [ -n "$KEYFILE" ]; then
        CHROOT="`sh -e "$HOSTBINDIR/mount-chroot" -k "$KEYFILE" \
                            $create $ENCRYPT -p -c "$CHROOTS" "$NAME"`"
    else
        CHROOT="`sh -e "$HOSTBINDIR/mount-chroot" \
                            $create $ENCRYPT -p -c "$CHROOTS" "$NAME"`"
    fi

    # Auto-unmount the chroot when the script exits
    TRAP="sh -e '$HOSTBINDIR/unmount-chroot' \
                    -y -c '$CHROOTS' '$NAME' 2>/dev/null || true;$TRAP"
    trap "$TRAP" INT HUP 0

    # Sanity-check the release if we're updating
    if [ -n "$NODOWNLOAD" ] \
            && ! grep -q "=$RELEASE\$" "$CHROOT/etc/lsb-release"; then
        error 1 "Release doesn't match! Please correct the -r option."
    fi

    mkdir -p "$BIN"
fi

# Unpack the tarball if appropriate
if [ -z "$NODOWNLOAD" -a -z "$DOWNLOADONLY" ]; then
    echo "Installing $RELEASE-$ARCH chroot to $CHROOT" 1>&2
    if [ -n "$TARBALL" ]; then
        # Unpack the chroot
        echo 'Unpacking chroot environment...' 1>&2
        tar -C "$CHROOT" --strip-components=1 -xf "$TARBALL"
    fi
elif [ -z "$NODOWNLOAD" ]; then
    echo "Downloading $RELEASE-$ARCH bootstrap to $TARBALL" 1>&2
fi

# Download the bootstrap data if appropriate
if [ -z "$NODOWNLOAD" ] && [ -n "$DOWNLOADONLY" -o -z "$TARBALL" ]; then
    # Create the temporary directory and delete it upon exit
    tmp="`mktemp -d --tmpdir=/tmp "$APPLICATION.XXX"`"
    subdir="$RELEASE-$ARCH"
    TRAP="rm -rf '$tmp';$TRAP"
    trap "$TRAP" INT HUP 0

    # Ensure that the temporary directory has exec+dev, or mount a new tmpfs
    if [ "$NOEXECTMP" = 'y' ]; then
        mount -i -t tmpfs -o 'rw,dev,exec' tmpfs "$tmp"
        TRAP="umount -f '$tmp';$TRAP"
        trap "$TRAP" INT HUP 0
    fi

    # Grab the latest release of debootstrap
    echo 'Downloading latest debootstrap...' 1>&2
    if ! wget -qO- 'http://anonscm.debian.org/gitweb/?p=d-i/debootstrap.git;a=snapshot;h=HEAD;sf=tgz' \
            | tar -C "$tmp" --strip-components=1 -zx 2>/dev/null; then
        echo 'Download from Debian gitweb failed. Trying latest release...' 1>&2
        d='http://ftp.debian.org/debian/pool/main/d/debootstrap/'
        f="`wget -qO- "$d" \
                | sed -ne 's ^.*\(debootstrap_[0-9.]*.tar.gz\).*$ \1 p' \
                | tail -n 1`"
        if [ -z "$f" ]; then
            error 1 'Failed to download debootstrap.
Check your internet connection or proxy settings and try again.'
        fi
        v="${f#*_}"
        v="${v%.tar.gz}"
        echo "Downloading debootstrap version $v..." 1>&2
        if ! wget -qO- "$d$f" \
                | tar -C "$tmp" --strip-components=1 -zx 2>/dev/null; then
            error 1 'Failed to download debootstrap.'
        fi
    fi

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

# Ensure that /usr/local/bin and /etc/crouton exist
mkdir -p "$CHROOT/usr/local/bin" "$CHROOT/etc/crouton"

# Create the setup script inside the chroot
echo 'Preparing chroot environment...' 1>&2
VAREXPAND="s #ARCH $ARCH ;s #MIRROR $MIRROR ;s #RELEASE $RELEASE ;"
VAREXPAND="${VAREXPAND}s #PROXY $PROXY ;s #VERSION $VERSION ;"
sed -e "$VAREXPAND" "$INSTALLERDIR/prepare.sh" > "$CHROOT/prepare.sh"
# Create a file for target deduplication
TARGETDEDUPFILE="`mktemp --tmpdir=/tmp "$APPLICATION.XXX"`"
rmtargetdedupfile="rm -f '$TARGETDEDUPFILE'"
TRAP="$rmtargetdedupfile;$TRAP"
trap "$TRAP" INT HUP 0
# Run each target, appending stdout to the prepare script.
unset SIMULATE
if [ -n "$TARGETFILE" ]; then
    TARGET="`readlink -f "$TARGETFILE"`"
    (. "$TARGET") >> "$CHROOT/prepare.sh"
fi
t="${TARGETS%,},post-common,"
while [ -n "$t" ]; do
    TARGET="${t%%,*}"
    t="${t#*,}"
    if [ -n "$TARGET" ]; then
        (. "$TARGETSDIR/$TARGET") >> "$CHROOT/prepare.sh"
    fi
done
chmod 500 "$CHROOT/prepare.sh"
# Delete the temp file
eval "$rmtargetdedupfile"

# Run the setup script inside the chroot
sh -e "$HOSTBINDIR/enter-chroot" -c "$CHROOTS" -n "$NAME" -x '/prepare.sh'

echo "Done! You can enter the chroot using enter-chroot." 1>&2
