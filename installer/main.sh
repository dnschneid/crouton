#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -e

APPLICATION="${0##*/}"
SCRIPTDIR="${SCRIPTDIR:-"`dirname "$0"`/.."}"
CHROOTBINDIR="$SCRIPTDIR/chroot-bin"
CHROOTETCDIR="$SCRIPTDIR/chroot-etc"
DISTRODIR=''
INSTALLERDIR="$SCRIPTDIR/installer"
HOSTBINDIR="$SCRIPTDIR/host-bin"
TARGETSDIR="$SCRIPTDIR/targets"
SRCDIR="$SCRIPTDIR/src"

ARCH=''
BOOTSTRAP_RELEASE=''
DISTRO=''
DOWNLOADONLY=''
ENCRYPT=''
KEYFILE=''
MIRROR=''
MIRROR2=''
NAME=''
PREFIX='/usr/local'
PROXY='unspecified'
RELEASE=''
RESTORE=''
DEFAULTRELEASE='precise'
TARBALL=''
TARGETS=''
TARGETFILE=''
UPDATE=''
UPDATEIGNOREEXISTING=''

USAGE="$APPLICATION [options] -t targets
$APPLICATION [options] -f backup_tarball
$APPLICATION [options] -d -f bootstrap_tarball

Constructs a chroot for running a more standard userspace alongside Chromium OS.

If run with -f, where the tarball is a backup previously made using edit-chroot,
the chroot is restored and relevant scripts installed.

If run with -d, a bootstrap tarball is created to speed up chroot creation in
the future. You can use bootstrap tarballs generated this way by passing them
to -f the next time you create a chroot with the same architecture and release.

$APPLICATION must be run as root unless -d is specified AND fakeroot is
installed AND /tmp is mounted exec and dev.

It is highly recommended to run this from a crosh shell (Ctrl+Alt+T), not VT2.

Options:
    -a ARCH     The architecture to prepare a new chroot or bootstrap for.
                Default: autodetected for the current chroot or system.
    -d          Downloads the bootstrap tarball but does not prepare the chroot.
    -e          Encrypt the chroot with ecryptfs using a passphrase.
                If specified twice, prompt to change the encryption passphrase.
    -f TARBALL  The bootstrap or backup tarball to use, or to download to in the
                case of -d. When using an existing tarball, -a and -r are ignored.
    -k KEYFILE  File or directory to store the (encrypted) encryption keys in.
                If unspecified, the keys will be stored in the chroot if doing a
                first encryption, or auto-detected on existing chroots.
    -m MIRROR   Mirror to use for bootstrapping and package installation.
                Default depends on the release chosen.
                Can only be specified during chroot creation and forced updates
                (-u -u). After installation, the mirror can be modified using
                the distribution's recommended way.
    -M MIRROR2  A secondary mirror, often used for security updates.
                Can only be specified alongside -m.
    -n NAME     Name of the chroot. Default is the release name.
                Cannot contain any slash (/).
    -p PREFIX   The root directory in which to install the bin and chroot
                subdirectories and data. Default: $PREFIX
    -P PROXY    Set an HTTP proxy for the chroot; effectively sets http_proxy.
                Specify an empty string to remove a proxy when updating.
    -r RELEASE  Name of the distribution release. Default: $DEFAULTRELEASE,
                or auto-detected if upgrading a chroot and -n is specified.
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
# "Undocumented" flags:
#   -U          Same as -u, but does not reinstall existing targets.
#               Targets specified with -t will be installed, but not recorded
#               for future updates.

# Common functions
. "$SCRIPTDIR/installer/functions"

# Process arguments
while getopts 'a:def:k:m:M:n:p:P:r:s:t:T:uUV' f; do
    case "$f" in
    a) ARCH="$OPTARG";;
    d) DOWNLOADONLY='y';;
    e) ENCRYPT="${ENCRYPT:-"-"}e";;
    f) TARBALL="$OPTARG";;
    k) KEYFILE="$OPTARG";;
    m) MIRROR="$OPTARG";;
    M) MIRROR2="$OPTARG";;
    n) NAME="$OPTARG";;
    p) PREFIX="`readlink -f "$OPTARG"`";;
    P) PROXY="$OPTARG";;
    r) RELEASE="$OPTARG";;
    t) TARGETS="$TARGETS${TARGETS:+","}$OPTARG";;
    T) TARGETFILE="$OPTARG";;
    u) UPDATE="$((UPDATE+1))";;
    U) UPDATE="$((UPDATE+1))"; UPDATEIGNOREEXISTING='y';;
    V) echo "$APPLICATION: version ${VERSION:-"git"}"; exit 0;;
    \?) error 2 "$USAGE";;
    esac
done
shift "$((OPTIND-1))"

# Check against the minimum version of Chromium OS
if ! awk -F= '/_RELEASE_VERSION=/ { exit int($2) < '"${CROS_MIN_VERS:-0}"' }' \
        '/etc/lsb-release' 2>/dev/null; then
    error 2 "Your version of Chromium OS is extraordinarily old.
If there are updates pending, please reboot and try again.
Otherwise, you may not be getting automatic updates, in which case you should
post your update_engine.log from chrome://system to http://crbug.com/296768 and
restore your device using a recovery USB: http://goo.gl/AZ74hj"
fi

# If the release is "list" or "help", print out all the valid releases.
if [ "$RELEASE" = 'list' -o "$RELEASE" = 'help' ]; then
    for DISTRODIR in "$INSTALLERDIR"/*/; do
        DISTRODIR="${DISTRODIR%/}"
        DISTRO="${DISTRODIR##*/}"
        echo "Recognized $DISTRO releases:" 1>&2
        accum=''
        while read RELEASE; do
            newaccum="${accum:-"   "} $RELEASE"
            if [ "${#newaccum}" -gt 80 ]; then
                echo "$accum" 1>&2
                newaccum="    $RELEASE"
            fi
            accum="$newaccum"
        done < "$DISTRODIR/releases"
        if [ -n "$accum" ]; then
            echo "$accum" 1>&2
        fi
    done
    echo 'Releases marked with * are unsupported, but may work with some effort.' 1>&2
    exit 2
fi

# Either a tarball, update, or target must be specified.
if [ -z "$TARBALL$UPDATE$TARGETS$TARGETFILE" ]; then
    error 2 "$USAGE"
fi

# Download only + update doesn't make sense
if [ -n "$DOWNLOADONLY" -a -n "$UPDATE" ]; then
    error 2 "$USAGE"
fi

# ARCH cannot be specified upon update
if [ -n "$UPDATE" -a -n "$ARCH" ]; then
    error 2 'Architecture cannot be specified when updating.'
fi

# MIRROR and MIRROR2 must not be specified on update
if [ "$UPDATE" = 1 ]; then
    if [ -z "$MIRROR$MIRROR2" ]; then
        # Makes sure MIRROR does not get overriden by distribution default
        MIRROR='unspecified'
    else
        error 2 "$USAGE"
    fi
fi

# Prefix must exist
if [ ! -d "$PREFIX" ]; then
    error 2 "$PREFIX is not a valid prefix"
fi

# There should never be any extra parameters.
if [ ! $# = 0 ]; then
    error 2 "$USAGE"
fi

# If this script was called with '-x' or '-v', pass that to prepare.sh
SETOPTIONS=""
if set -o | grep -q '^xtrace *on$'; then
    SETOPTIONS="-x"
fi
if set -o | grep -q '^verbose *on$'; then
    SETOPTIONS="$SETOPTIONS -v"
fi
sh() {
    /bin/sh $SETOPTIONS -e "$@"
}

if [ "$USER" = root -o "$UID" = 0 ]; then
    # Avoid kernel panics due to slow I/O when restoring or bootstrapping
    disablehungtask
fi

# If we specified a tarball, we need to detect the tarball type
if [ -z "$DOWNLOADONLY" -a -n "$TARBALL" ]; then
    if [ ! -f "$TARBALL" ]; then
        error 2 "$TARBALL not found."
    fi
    label="`tar --test-label -f "$TARBALL" 2>/dev/null`"
    if [ -n "$label" ]; then
        if [ "${label#crouton:backup}" != "$label" ]; then
            releasearch=''
            if [ -z "$NAME" ]; then
                NAME="${label#*-}"
            fi
        elif [ "${label#crouton:bootstrap}" != "$label" ]; then
            releasearch="${label#*.}"
        else
            error 2 "$TARBALL doesn't appear to be a valid crouton bootstrap."
        fi
    else
        # Old bootstraps just use the first folder name
        echo "WARNING: $TARBALL is an old-style bootstrap or backup." 1>&2
        releasearch="`tar -tf "$TARBALL" 2>/dev/null | head -n 1`"
        releasearch="${releasearch%%/*}"
    fi
    if [ "${releasearch#*-}" != "$releasearch" ]; then
        ARCH="${releasearch#*-}"
        RELEASE="${releasearch%-*}"
    else
        RESTORE='y'
        if [ -z "$NAME" ]; then
            NAME="$releasearch"
        fi
    fi
elif [ -n "$DOWNLOADONLY" -a -s "$TARBALL" ]; then
    error 2 "$TARBALL already exists; refusing to overwrite it!"
fi

# If we're not restoring, updating, or bootstrapping, targets must be specified
if [ -z "$RESTORE$UPDATE$DOWNLOADONLY$TARGETS$TARGETFILE" ]; then
    error 2 "$USAGE"
fi

if [ -n "$RESTORE" -a -n "$TARGETS$TARGETFILE" -a -z "$UPDATE" ]; then
    error 2 "Specify -u if you want to add targets when you restore a chroot."
fi

# Detect which distro the release belongs to.
if [ -n "$RELEASE" -o -z "$UPDATE" ]; then
    if [ -z "$RELEASE" ]; then
        RELEASE="$DEFAULTRELEASE"
    fi
    for DISTRODIR in "$INSTALLERDIR"/*/; do
        DISTRODIR="${DISTRODIR%/}"
        releaseline="`grep "^$RELEASE[^a-z]*$" "$DISTRODIR/releases" || true`"
        if [ -n "$releaseline" ]; then
            DISTRO="${DISTRODIR##*/}"
            . "$DISTRODIR/defaults"
            break
        fi
    done
    if [ -z "$DISTRO" ]; then
        error 2 "$RELEASE does not belong to any supported distribution."
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

# Set http_proxy if a proxy is specified.
if [ ! "$PROXY" = 'unspecified' ]; then
    export http_proxy="$PROXY" https_proxy="$PROXY" ftp_proxy="$PROXY"
fi

# Done with parameter processing!
# Make sure we always have echo when this script exits
addtrap "stty echo 2>/dev/null"

# Deterime directories, and fix NAME if it was not specified.
BIN="$PREFIX/bin"
CHROOTS="$PREFIX/chroots"
CHROOT="$CHROOTS/${NAME:="${RELEASE:-"$DEFAULTRELEASE"}"}"
CHROOTSRC="$CHROOT"
TARGETDEDUPFILE="$CHROOT/.crouton-targets"

# Validate chroot name
if ! validate_name "$NAME"; then
    error 2 "Invalid chroot name '$NAME'."
fi

# Confirm we have write access to the directory before starting.
if [ -z "$DOWNLOADONLY" ]; then
    create='-n'
    if [ -d "$CHROOT" ] && ! rmdir "$CHROOT" 2>/dev/null; then
        if [ -n "$RESTORE" ]; then
            error 1 "$CHROOTSRC already has stuff in it!
Either delete it, specify a different name (-n), or use edit-chroot to restore."
        elif [ -z "$UPDATE" ]; then
            error 1 "$CHROOTSRC already has stuff in it!
Either delete it, specify a different name (-n), or specify -u to update it."
        fi
        create=''
        echo "$CHROOTSRC already exists; updating it..." 1>&2
    elif [ -n "$UPDATE" -a -z "$RESTORE" ]; then
        error 1 "$CHROOTSRC does not exist; cannot update."
    fi

    # Restore the chroot now
    if [ -n "$RESTORE" ]; then
        sh "$HOSTBINDIR/edit-chroot" -r -f "$TARBALL" -c "$CHROOTS" -- "$NAME"
    fi

    # Mount the chroot and update CHROOT path
    if [ -n "$KEYFILE" ]; then
        CHROOT="`sh "$HOSTBINDIR/mount-chroot" -k "$KEYFILE" \
                            $create $ENCRYPT -p -c "$CHROOTS" -- "$NAME"`"
    else
        CHROOT="`sh "$HOSTBINDIR/mount-chroot" \
                            $create $ENCRYPT -p -c "$CHROOTS" -- "$NAME"`"
    fi

    # Auto-unmount the chroot when the script exits
    addtrap "sh '$HOSTBINDIR/unmount-chroot' -y -c '$CHROOTS' -- '$NAME' 2>/dev/null"

    # Sanity-check the release if we're updating
    if [ -n "$UPDATE" -a -n "$RELEASE" ] &&
            [ "`sh "$DISTRODIR/getrelease.sh" -r "$CHROOT"`" != "$RELEASE" ]; then
        if [ ! "$UPDATE" = 2 ]; then
            error 1 \
"Release doesn't match! Please correct the -r option, or specify a second -u to
change the release, upgrading the chroot (dangerous)."
        else
            echo "WARNING: Changing the chroot release to $RELEASE." 2>&1
            echo "Press Control-C to abort; upgrade will continue in 5 seconds." 1>&2
            sleep 5
        fi
    elif [ -n "$UPDATE" -a -z "$RELEASE" ]; then
        # Detect the release
        for DISTRODIR in "$INSTALLERDIR"/*/; do
            DISTRODIR="${DISTRODIR%/}"
            if RELEASE="`sh "$DISTRODIR/getrelease.sh" -r "$CHROOT"`"; then
                DISTRO="${DISTRODIR##*/}"
                . "$DISTRODIR/defaults"
                break
            fi
        done
        if [ -z "$DISTRO" ]; then
            error 2 "Unable to determine the release in $CHROOTSRC. Please specify it with -r."
        fi
    fi

    # Enforce the correct architecture
    if [ -n "$UPDATE" ]; then
        ARCH="`sh "$DISTRODIR/getrelease.sh" -a "$CHROOT"`"
    fi

    mkdir -p "$BIN"
fi

# Check if RELEASE is supported
releaseline="`grep "^$RELEASE[^a-z]*$" "$DISTRODIR/releases" || true`"
if [ "${releaseline%"*"}" != "$releaseline" ]; then
    echo "WARNING: $RELEASE is an unsupported release.
You will likely run into issues, but things may work with some effort." 1>&2

    if [ -z "$UPDATE" ]; then
        echo "Press Ctrl-C to abort; installation will continue in 5 seconds." 1>&2
    else
        echo "\
If this is a surprise to you, $RELEASE has probably reached end of life.
Refer to http://goo.gl/Z5LGVD for upgrade instructions." 1>&2
    fi
    sleep 5
fi

# Checks if it's safe to enable boot signing verification.
# We check by attempting to mount / read-write. We do so in a bind mount to a
# temporary directory to avoid changing its state permanently if it is
# successful.
vboot_is_safe() {
    local tmp="`mktemp -d --tmpdir=/tmp 'crouton-rwtest.XXX'`"
    local unmount="umount -l '$tmp' 2>/dev/null; rmdir '$tmp'"
    addtrap "$unmount"
    mount --bind / "$tmp" >/dev/null
    local ret=1
    mount -o remount,rw "$tmp" 2>/dev/null || ret=0
    undotrap
    eval "$unmount"
    return "$ret"
}

# Check and update dev boot settings. This may fail on old systems; ignore it.
if [ -z "$DOWNLOADONLY" ] && ! vboot_is_safe; then
    echo "WARNING: Your rootfs is writable. Signed boot verification cannot be enabled." 1>&2
    echo "If this is a surprise to you, you should do a full system recovery via USB." 1>&2
    sleep 5
elif [ -z "$DOWNLOADONLY" ] && \
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
if [ -z "$RESTORE" -a -z "$UPDATE" -a -z "$DOWNLOADONLY" ]; then
    echo "Installing $RELEASE-$ARCH chroot to $CHROOTSRC" 1>&2
    if [ -n "$TARBALL" ]; then
        # Unpack the chroot
        echo 'Unpacking chroot environment...' 1>&2
        tar -C "$CHROOT" --strip-components=1 -xf "$TARBALL"
    fi
elif [ -z "$RESTORE" -a -z "$UPDATE" ]; then
    echo "Downloading $RELEASE-$ARCH bootstrap to $TARBALL" 1>&2
fi

# Download the bootstrap data if appropriate
if [ -z "$UPDATE" ] && [ -n "$DOWNLOADONLY" -o -z "$TARBALL" ]; then
    # Create the temporary directory and delete it upon exit
    tmp="`mktemp -d --tmpdir=/tmp "$APPLICATION.XXX"`"
    subdir="$RELEASE-$ARCH"
    addtrap "rm -rf --one-file-system '$tmp'"

    # Ensure that the temporary directory has exec+dev, or mount a new tmpfs
    if [ "$NOEXECTMP" = 'y' ]; then
        mount -i -t tmpfs -o 'rw,dev,exec' tmpfs "$tmp"
        addtrap "umount -l '$tmp'"
    fi

    . "$DISTRODIR/bootstrap"

    # Tar it up if we're only downloading
    if [ -n "$DOWNLOADONLY" ]; then
        echo 'Compressing bootstrap files...' 1>&2
        $FAKEROOT tar -C "$tmp" -V "crouton:bootstrap.$subdir" \
                      -cajf "$TARBALL" "$subdir"
        echo 'Done!' 1>&2
        exit 0
    fi

    # Move it to the right place
    echo 'Moving bootstrap files into the chroot...' 1>&2
    # Make sure we do not leave an incomplete chroot in case of interrupt or
    # error during the move
    addtrap "rm -rf --one-file-system '$CHROOT'"
    mv -f "$tmp/$subdir/"* "$CHROOT"
    undotrap
fi

# Ensure that /usr/local/bin and /etc/crouton exist
mkdir -p "$CHROOT/usr/local/bin" "$CHROOT/etc/crouton"

# Create the setup script inside the chroot
echo 'Preparing chroot environment...' 1>&2
VAREXPAND="s/releases=.*\$/releases=\"\
`sed 's/$/\\\\/' "$DISTRODIR/releases"`
\"/;"
VAREXPAND="${VAREXPAND}s #ARCH# $ARCH ;s #DISTRO# $DISTRO ;"
VAREXPAND="${VAREXPAND}s #MIRROR# $MIRROR ;s #MIRROR2# $MIRROR2 ;"
VAREXPAND="${VAREXPAND}s #RELEASE# $RELEASE ;s #PROXY# $PROXY ;"
VAREXPAND="${VAREXPAND}s #VERSION# ${VERSION:-"git"} ;"
VAREXPAND="${VAREXPAND}s #USERNAME# $CROUTON_USERNAME ;"
VAREXPAND="${VAREXPAND}s/#SETOPTIONS#/$SETOPTIONS/;"
installscript "$INSTALLERDIR/prepare.sh" "$CHROOT/prepare.sh" "$VAREXPAND"
# Append the distro-specific prepare.sh
cat "$DISTRODIR/prepare" >> "$CHROOT/prepare.sh"
# If -U was not specified, update existing targets.
if [ -z "$UPDATEIGNOREEXISTING" ]; then
    # Read the explicit targets file in the chroot (if it exists)
    TARGETSFILE="$CHROOT/etc/crouton/targets"
    if [ -r "$TARGETSFILE" ]; then
        read t < "$TARGETSFILE"
        t="${t%,},"
        while [ -n "$t" ]; do
            TARGET="${t%%,*}"
            t="${t#*,}"
            if [ -z "$TARGET" ]; then
                continue
            fi
            # Don't put duplicate entries in the targets list
            tlist=",$TARGETS,"
            if [ ! "${tlist%",$TARGET,"*}" = "$tlist" ]; then
                continue
            fi
            if [ ! -r "$TARGETSDIR/$TARGET" ]; then
                echo "Previously installed target '$TARGET' no longer exists." 1>&2
                continue
            fi
            # Add the target
            TARGETS="${TARGETS%,},$TARGET"
        done
    fi
    # Reset the installed target list files
    echo "$TARGETS" > "$TARGETSFILE"
fi
echo -n '' > "$TARGETDEDUPFILE"
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

if [ -z "$RESTORE" -o -n "$UPDATE" ]; then
    chmod 500 "$CHROOT/prepare.sh"

    # Run the setup script inside the chroot
    sh -e "$HOSTBINDIR/enter-chroot" -c "$CHROOTS" -n "$NAME" -xx
else
    # We don't actually need to run the prepare.sh when only restoring
    rm -f "$CHROOT/prepare.sh"
fi

echo "Done! You can enter the chroot using enter-chroot." 1>&2
