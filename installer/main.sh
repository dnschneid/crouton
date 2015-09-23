#!/bin/sh -e
# Copyright (c) 2015 The crouton Authors. All rights reserved.
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
PREFIXSET=''
CHROOTSLINK='/mnt/stateful_partition/crouton/chroots'
PROXY='unspecified'
RELEASE=''
RESTORE=''
RESTOREBIN=''
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
    -b          Restore crouton scripts in PREFIX/bin, as required by the
                chroots currently installed in PREFIX/chroots.
    -d          Downloads the bootstrap tarball but does not prepare the chroot.
    -e          Encrypt the chroot with ecryptfs using a passphrase.
                If specified twice, prompt to change the encryption passphrase.
    -f TARBALL  The bootstrap or backup tarball to use, or to download to (-d).
                When using an existing tarball, -a and -r are ignored.
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
                subdirectories and data.
                Default: $PREFIX, with $PREFIX/chroots linked to
                $CHROOTSLINK.
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
while getopts 'a:bdef:k:m:M:n:p:P:r:s:t:T:uUV' f; do
    case "$f" in
    a) ARCH="$OPTARG";;
    b) RESTOREBIN='y';;
    d) DOWNLOADONLY='y';;
    e) ENCRYPT="${ENCRYPT:-"-"}e";;
    f) TARBALL="$OPTARG";;
    k) KEYFILE="$OPTARG";;
    m) MIRROR="$OPTARG";;
    M) MIRROR2="$OPTARG";;
    n) NAME="$OPTARG";;
    p) PREFIX="`readlink -m -- "$OPTARG"`"; PREFIXSET='y';;
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
restore your device using a recovery USB: https://goo.gl/AZ74hj"
fi

# If the release is "list" or "help", print out all the valid releases.
if [ "$RELEASE" = 'list' -o "$RELEASE" = 'help' ]; then
    for DISTRODIR in "$INSTALLERDIR"/*/; do
        DISTRODIR="${DISTRODIR%/}"
        DISTRO="${DISTRODIR##*/}"
        echo "Recognized $DISTRO releases:" 1>&2
        accum=''
        while IFS="|" read -r RELEASE _; do
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

# Either a tarball, update, target, or restore binaries must be specified.
if [ -z "$TARBALL$UPDATE$TARGETS$TARGETFILE$RESTOREBIN" ]; then
    error 2 "$USAGE"
fi

# Only one of 'download only', update and restore binaries can be specified
test="$DOWNLOADONLY${UPDATE:+y}$RESTOREBIN"
if [ "${#test}" -gt 1 ]; then
    error 2 "$USAGE"
fi

# ARCH cannot be specified upon update
if [ -n "$UPDATE$RESTOREBIN" -a -n "$ARCH" ]; then
    error 2 'Architecture cannot be specified with -b or -u.'
fi

# Release or name cannot be specified when restoring binaries
if [ -n "$RESTOREBIN" -a -n "$NAME$RELEASE$ENCRYPT" ]; then
    error 2 "Name, release and encrypt cannot be specified with -b."
fi

# MIRROR and MIRROR2 must not be specified on update
if [ "$UPDATE" = 1 -o -n "$RESTOREBIN" ]; then
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
if set -o | grep -q '^xtrace.*on$'; then
    SETOPTIONS="-x"
fi
if set -o | grep -q '^verbose.*on$'; then
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
if [ -z "$RESTORE$RESTOREBIN$UPDATE$DOWNLOADONLY$TARGETS$TARGETFILE" ]; then
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
        if grep -q "^$RELEASE\([^a-z].*\)*$" "$DISTRODIR/releases"; then
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
                    (TARGETNOINSTALL='y'; . "$t") 1>&2
                fi
            done
            exit 2
        elif [ ! "${TARGET%common}" = "$TARGET" ] || \
             [ ! -r "$TARGETSDIR/$TARGET" ] || \
             ! (TARGETNOINSTALL="${UPDATE:-c}"; . "$TARGETSDIR/$TARGET"); then
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

# Determine directories
BIN="$PREFIX/bin"
CHROOTS="$PREFIX/chroots"

if [ -z "$RESTOREBIN" ]; then
    # Fix NAME if it was not specified.
    CHROOT="$CHROOTS/${NAME:="${RELEASE:-"$DEFAULTRELEASE"}"}"
    CHROOTSRC="$CHROOT"
fi
TARGETDEDUPFILE="`mktemp --tmpdir=/tmp "$APPLICATION-dedup.XXX"`"
addtrap "rm -f '$TARGETDEDUPFILE'"

# Confirm we have write access to the directory before starting.
if [ -z "$RESTOREBIN$DOWNLOADONLY" ]; then
    # Validate chroot name
    if ! validate_name "$NAME"; then
        error 2 "Invalid chroot name '$NAME'."
    fi

    # If no prefix is set, check that /usr/local/chroots ($CHROOTS) is a
    # symbolic link to /mnt/stateful_partition/crouton/chroots ($CHROOTSLINK)
    # /mnt/stateful_partition/dev_image is bind-mounted to /usr/local, so mv
    # does not understand that they are on the same filesystem
    # Instead, use the direct path, and confirm that they're actually the same
    # to catch situations where things are bind-mounted over /usr/local
    truechroots="/mnt/stateful_partition/dev_image/chroots"
    if [ -z "$PREFIXSET" -a ! -h "$CHROOTS" ] \
            && ([ ! -e "$CHROOTS" ] || [ "$CHROOTS" -ef "$truechroots" ]); then
        # Detect if chroots are left in the old chroots directory, and move them
        # to the new directory.
        if [ -e "$CHROOTS" ] && ! rmdir "$CHROOTS" 2>/dev/null; then
            echo \
"Migrating data from legacy chroots directory $CHROOTS to $CHROOTSLINK..." 1>&2

            # Check that CHROOTSLINK is empty
            if [ -e "$CHROOTSLINK" ] && ! rmdir "$CHROOTSLINK" 2>/dev/null; then
                error 1 \
"There is data in both $CHROOTS and $CHROOTSLINK.
Make sure all chroots are unmounted, then manually move the contents of
$truechroots to $CHROOTSLINK."
            fi

            # Wait for currently-mounted chroots to be unmounted
            if grep -q "$CHROOTS" /proc/mounts && \
                    ! sh "$HOSTBINDIR/unmount-chroot" -a -y -c "$CHROOTS"; then
                echo -n \
"The above chroots appear to be running from the legacy chroots directory.
Log out of all running chroots and the install will automatically continue.
Press Ctrl-C at any time to abort the installation." 1>&2
                while grep -q "$CHROOTS" /proc/mounts; do
                    sleep 1
                done
                echo 1>&2
            fi

            mkdir -p "$CHROOTSLINK"
            mv -T "$truechroots" "$CHROOTSLINK"
        fi
        ln -sT "$CHROOTSLINK" "$CHROOTS"
    fi

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
        error 1 "$CHROOTSRC does not exist; cannot update.
Valid chroots:
`sh "$HOSTBINDIR/edit-chroot" -c "$CHROOTS" -a`"
    fi

    # Chroot must be located on an ext filesystem
    if df -T "`getmountpoint "$CHROOT"`" | awk '$2~"^ext"{exit 1}'; then
        error 1 "$CHROOTSRC is not an ext filesystem."
    fi

    # Restore the chroot now
    if [ -n "$RESTORE" ]; then
        sh "$HOSTBINDIR/edit-chroot" -r -f "$TARBALL" -c "$CHROOTS" -- "$NAME"
    fi

    # Mount the chroot and update CHROOT path
    CHROOT="`sh "$HOSTBINDIR/mount-chroot" -k "$KEYFILE" \
             $create $ENCRYPT -p -c "$CHROOTS" -- "$NAME"`"

    # Remove the directory if bootstrapping fails. Also delete if the only file
    # there is .ecryptfs (valid chroots have far more than 1 file)
    addtrap "[ \"\`ls -a '$CHROOTS/$NAME' 2>/dev/null | wc -l\`\" -le 3 ] \
                && rm -rf '$CHROOTS/$NAME'"

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
            echo "WARNING: Changing the chroot release to $RELEASE." 1>&2
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
releaseline="`sed -n "s/^\($RELEASE[^a-z|]*\)\(|.*\)*$/\1/p" \
                                                         "$DISTRODIR/releases"`"
if [ "${releaseline%"*"}" != "$releaseline" ]; then
    echo "WARNING: $RELEASE is an unsupported release.
You will likely run into issues, but things may work with some effort." 1>&2

    if [ -z "$UPDATE" ]; then
        echo "Press Ctrl-C to abort; installation will continue in 5 seconds." 1>&2
    else
        echo "\
If this is a surprise to you, $RELEASE has probably reached end of life.
Refer to https://goo.gl/Z5LGVD for upgrade instructions." 1>&2
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
    mount --bind / "$tmp" >/dev/null 2>&1
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
        read -r usb legacy signed
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
if [ -z "$RESTOREBIN$RESTORE$UPDATE$DOWNLOADONLY" ]; then
    echo "Installing $RELEASE-$ARCH chroot to $CHROOTSRC" 1>&2
    if [ -n "$TARBALL" ]; then
        # Unpack the chroot
        echo 'Unpacking chroot environment...' 1>&2
        tar -C "$CHROOT" --strip-components=1 -xf "$TARBALL"
    fi
elif [ -z "$RESTOREBIN$RESTORE$UPDATE" ]; then
    echo "Downloading $RELEASE-$ARCH bootstrap to $TARBALL" 1>&2
fi

# Download the bootstrap data if appropriate
if [ -z "$UPDATE$RESTOREBIN" ] && [ -n "$DOWNLOADONLY" -o -z "$TARBALL" ]; then
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

# Add the list of targets in file $1 to $TARGETS
deduptargets() {
    if [ -r "$1" ]; then
        t="`tr '\n' , < "$1"`"
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
}

if [ -z "$RESTOREBIN" ] && [ -z "$RESTORE" -o -n "$UPDATE" ]; then
    PREPARE="$CHROOT/prepare.sh"

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
    installscript "$INSTALLERDIR/prepare.sh" "$PREPARE" "$VAREXPAND"
    # Append the distro-specific prepare.sh
    cat "$DISTRODIR/prepare" >> "$PREPARE"
else # Restore host-bin only
    PREPARE="/dev/null"

    # Make sure targets are aware that we only want to restore host-bin
    RESTOREHOSTBIN='y'
fi

if [ -z "$RESTOREBIN" ]; then
    # Ensure that /usr/local/bin and /etc/crouton exist
    mkdir -p "$CHROOT/usr/local/bin" "$CHROOT/etc/crouton"

    # If -U was not specified, update existing targets.
    if [ -z "$UPDATEIGNOREEXISTING" ]; then
        TARGETSFILE="$CHROOT/etc/crouton/targets"

        # Read the explicit targets file in the chroot
        deduptargets "$TARGETSFILE"

        if [ -z "$TARGETS" ]; then
            error 1 "\
No target list found (your chroot may be very old).
Please specify targets with -t."
        fi

        # Reset the installed target list files
        echo "$TARGETS" > "$TARGETSFILE"
    fi
else
    # Collect targets over all chroots (ignore the ones that cannot be mounted)
    for chroot in "$CHROOTS"/*; do
        deduptargets "$chroot/.crouton-targets"
    done
fi

echo -n '' > "$TARGETDEDUPFILE"
# Check if a target has defined PROVIDES, if we are not restoring host-bin.
if [ ! -n "$RESTOREHOSTBIN" ]; then
    # Create temporary file to list PROVIDES=TARGET.
    PROVIDESFILE="`mktemp --tmpdir=/tmp "$APPLICATION-provides.XXX"`"
    addtrap "rm -f '$PROVIDESFILE'"
    t="${TARGETS%,},"
    while [ -n "$t" ]; do
        TARGET="${t%%,*}"
        t="${t#*,}"
        if [ -n "$TARGET" ]; then
            (TARGETNOINSTALL="p"; . "$TARGETSDIR/$TARGET")
        fi
    done
fi

# Run each target, appending stdout to the prepare script.
unset SIMULATE
TARGETNOINSTALL="$RESTOREHOSTBIN"
if [ -n "$TARGETFILE" ]; then
    TARGET="`readlink -f -- "$TARGETFILE"`"
    (. "$TARGET") >> "$PREPARE"
fi
t="${TARGETS%,},post-common,"
while [ -n "$t" ]; do
    TARGET="${t%%,*}"
    t="${t#*,}"
    if [ -n "$TARGET" ]; then
        (. "$TARGETSDIR/$TARGET") >> "$PREPARE"
    fi
done

if [ -f "$PREPARE" ]; then
    # Update .crouton-targets in the unencrypted part of the chroot
    cp -fT "$TARGETDEDUPFILE" "$CHROOTSRC/.crouton-targets"

    chmod 500 "$PREPARE"

    # Run the setup script inside the chroot
    sh -e "$HOSTBINDIR/enter-chroot" -c "$CHROOTS" -n "$NAME" -xx
fi

echo "Done! You can enter the chroot using enter-chroot." 1>&2
