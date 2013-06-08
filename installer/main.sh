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

ARCH=''
DISTRO=''
DOWNLOADONLY=''
ENCRYPT=''
KEYFILE=''
MIRROR=''
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

Constructs a chroot for running a more standard userspace alongside Chromium OS.

If run with -f, a tarball is used to bootstrap the chroot. If specified with -d,
the tarball is created for later use with -f.

This must be run as root unless -d is specified AND fakeroot is installed AND
/tmp is mounted exec and dev.

It is highly recommended to run this from a crosh shell (Ctrl+Alt+T), not VT2.

Options:
    -a ARCH     The architecture to prepare the chroot for.
                Default: autodetected for the current system.
    -d          Downloads the bootstrap tarball but does not prepare the chroot.
    -e          Encrypt the chroot with ecryptfs using a passphrase.
                If specified twice, prompt to change the encryption passphrase.
    -f TARBALL  The tarball to use, or download to in the case of -d.
                When using a prebuilt tarball, -a and -r are ignored.
    -k KEYFILE  File or directory to store the (encrypted) encryption keys in.
                If unspecified, the keys will be stored in the chroot if doing a
                first encryption, or auto-detected on existing chroots.
    -m MIRROR   Mirror to use for bootstrapping and apt-get.
                Default depends on the release chosen.
    -n NAME     Name of the chroot. Default is the release name.
    -p PREFIX   The root directory in which to install the bin and chroot
                subdirectories and data. Default: $PREFIX
    -P PROXY    Set an HTTP proxy for the chroot; effectively sets http_proxy.
                Specify an empty string to remove a proxy when updating.
    -r RELEASE  Name of the distribution release. Default: $RELEASE
                Specify 'help' or 'list' to print out recognized releases.
    -t TARGETS  Comma-separated list of environment targets to install.
                Specify 'help' or 'list' to print out potential targets.
    -T TARGETFILE  Path to a custom target definition file that gets applied to
                the chroot as if it were a target in the $APPLICATION bundle.
    -u          If the chroot exists, runs the preparation step again.
                You can use this to install new targets or update old ones.
                Passing this parameter twice will force an update even if the
                specified release does not match the one already installed.
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

# Setup trap ($1) in case of interrupt or error.
# Traps are first disabled to avoid executing clean-up commands twice.
# In the case of interrupts, exit is called to avoid the script continuing.
# $1 must either be empty or end in a semicolon.
settrap() {
    trap "trap - INT HUP 0; $1 exit 2" INT HUP
    trap "trap - INT HUP 0; $1" 0
}

# Prepend a command to the existing $TRAP
addtrap() {
    OLDTRAP="$TRAP"
    TRAP="$1;$TRAP"
    settrap "$TRAP"
}

# Revert the last trap change
undotrap() {
    TRAP="$OLDTRAP"
    settrap "$TRAP"
}

# Process arguments
while getopts 'a:def:k:m:n:p:P:r:s:t:T:uV' f; do
    case "$f" in
    a) ARCH="$OPTARG";;
    d) DOWNLOADONLY='y';;
    e) ENCRYPT="${ENCRYPT:-"-"}e";;
    f) TARBALL="$OPTARG";;
    k) KEYFILE="$OPTARG";;
    m) MIRROR="$OPTARG";;
    n) NAME="$OPTARG";;
    p) PREFIX="`readlink -f "$OPTARG"`";;
    P) PROXY="$OPTARG";;
    r) RELEASE="$OPTARG";;
    t) TARGETS="$TARGETS${TARGETS:+","}$OPTARG";;
    T) TARGETFILE="$OPTARG";;
    u) UPDATE="$((UPDATE+1))";;
    V) echo "$APPLICATION: version ${VERSION:-"git"}"; exit 0;;
    \?) error 2 "$USAGE";;
    esac
done
shift "$((OPTIND-1))"

# If targets weren't specified, we should just print help text.
if [ -z "$DOWNLOADONLY" -a -z "$TARGETS" -a -z "$TARGETFILE" \
        -a ! "$RELEASE" = 'list' -a ! "$RELEASE" = 'help' ]; then
    error 2 "$USAGE"
fi

# There should never be any extra parameters.
if [ ! $# = 0 ]; then
    error 2 "$USAGE"
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

# If the release is "list" or "help", print out all the valid releases.
if [ "$RELEASE" = 'list' -o "$RELEASE" = 'help' ]; then
    for dist in "$INSTALLERDIR"/*/; do
        DISTRO="${dist%/}"
        DISTRO="${DISTRO##*/}"
        echo "Recognized $DISTRO releases:" 1>&2
        echo -n '   ' 1>&2
        while read RELEASE; do
            echo -n " $RELEASE" 1>&2
        done < "$dist/releases"
        echo 1>&2
    done
    exit 2
fi

# Detect which distro the release belongs to.
for dist in "$INSTALLERDIR"/*/; do
    if grep -q "^$RELEASE\$" "$dist/releases"; then
        DISTRO="${dist%/}"
        DISTRO="${DISTRO##*/}"
        . "$dist/defaults"
        break
    fi
done
if [ -z "$DISTRO" ]; then
    error 2 "$RELEASE does not belong to any supported distribution."
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

# Set http_proxy if a proxy is specified.
if [ ! "$PROXY" = 'unspecified' ]; then
    export http_proxy="$PROXY" https_proxy="$PROXY" ftp_proxy="$PROXY"
fi

# Done with parameter processing!
# Make sure we always have echo when this script exits
addtrap "stty echo 2>/dev/null || true"

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
    addtrap "sh -e '$HOSTBINDIR/unmount-chroot' \
                    -y -c '$CHROOTS' '$NAME' 2>/dev/null || true"

    # Sanity-check the release if we're updating
    if [ -n "$NODOWNLOAD" ] \
            && ! grep -q "=$RELEASE\$" "$CHROOT/etc/lsb-release"; then
        if [ ! "$UPDATE" = 2 ]; then
            error 1 \
"Release doesn't match! Please correct the -r option, or specify a second -u to
change the release, upgrading the chroot (dangerous)."
        else
            echo "WARNING: Changing the chroot release to $RELEASE." 2>&1
            echo "Press Control-C to abort; upgrade will continue in 5 seconds." 1>&2
            sleep 5
        fi
    fi

    mkdir -p "$BIN"
fi

# Check and update dev boot settings. This may fail on old systems; ignore it.
if [ -z "$DOWNLOADONLY" ] && \
    boot="`crossystem dev_boot_usb dev_boot_legacy dev_boot_signed_only`"; then
    # db_usb and db_legacy be off, db_signed_only should be on.
    echo "$boot" | {
        read usb legacy signed
        suggest=''
        if [ ! "$usb" = 0 ]; then
            echo "WARNING: USB booting is enabled; consider disabling it." 1>&2
            suggest="$suggest dev_boot_usb=0"
        fi
        if [ ! "$legacy" = 0 ]; then
            echo "WARNING: Legacy booting is enabled; consider disabling it." 1>&2
            suggest="$suggest dev_boot_legacy=0"
        fi
        if [ -n "$suggest" ]; then
            if [ ! "$signed" = 1 ]; then
                echo "WARNING: Signed boot verification is disabled; consider enabling it." 1>&2
                suggest="$suggest dev_boot_signed_only=1"
            fi
            echo "You can use the following command: sudo crossystem$suggest" 1>&2
            sleep 5
        elif [ ! "$signed" = 1 ]; then
            # Only enable signed booting if the user hasn't enabled alternate
            # boot options, since those are opt-in.
            echo "WARNING: Signed boot verification is disabled; enabling it for security." 1>&2
            echo "You can disable it again using: sudo crossystem dev_boot_signed_only=0" 1>&2
            crossystem dev_boot_signed_only=1 || true
            sleep 2
        fi
    }
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
    addtrap "rm -rf '$tmp'"

    # Ensure that the temporary directory has exec+dev, or mount a new tmpfs
    if [ "$NOEXECTMP" = 'y' ]; then
        mount -i -t tmpfs -o 'rw,dev,exec' tmpfs "$tmp"
        addtrap "umount -f '$tmp'"
    fi

    . "$INSTALLERDIR/$DISTRO/bootstrap"

    # Tar it up if we're only downloading
    if [ -n "$DOWNLOADONLY" ]; then
        echo 'Compressing bootstrap files...' 1>&2
        $FAKEROOT tar -C "$tmp" -cajf "$TARBALL" "$subdir"
        echo 'Done!' 1>&2
        exit 0
    fi

    # Move it to the right place
    echo 'Moving bootstrap files into the chroot...' 1>&2
    # Make sure we do not leave an incomplete chroot in case of interrupt or
    # error during the move
    addtrap "rm -rf '$CHROOT'"
    mv -f "$tmp/$subdir/"* "$CHROOT"
    undotrap
fi

# Ensure that /usr/local/bin and /etc/crouton exist
mkdir -p "$CHROOT/usr/local/bin" "$CHROOT/etc/crouton"

# Create the setup script inside the chroot
echo 'Preparing chroot environment...' 1>&2
VAREXPAND="s #ARCH $ARCH ;s #MIRROR $MIRROR ;"
VAREXPAND="${VAREXPAND}s #DISTRO $DISTRO ;s #RELEASE $RELEASE ;"
VAREXPAND="${VAREXPAND}s #PROXY $PROXY ;s #VERSION $VERSION ;"
sed -e "$VAREXPAND" "$INSTALLERDIR/prepare.sh" > "$CHROOT/prepare.sh"
# Append the distro-specific prepare.sh
cat "$INSTALLERDIR/$DISTRO/prepare" >> "$CHROOT/prepare.sh"
# Create a file for target deduplication
TARGETDEDUPFILE="`mktemp --tmpdir=/tmp "$APPLICATION.XXX"`"
rmtargetdedupfile="rm -f '$TARGETDEDUPFILE'"
addtrap "$rmtargetdedupfile"
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
