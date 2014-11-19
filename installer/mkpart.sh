#!/bin/sh -e
# Copyright (c) 2014 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -e

if [ -z "$APPLICATION" -o -z "$PREFIX" ]; then
    echo "Please do not call mkpart.sh directly: use main.sh -S." 1>&2
    exit 2
fi

# Partition number to use
CROUTONPARTNUMBER=13
CROUTONPARTNUMBERSET=''
# Minimum stateful partition size in MB
MINIMUMSTATEFULSIZE=1500
# Give at least 10%, and 200 MB, headroom in the current stateful partition
MINIMUMSTATEFULMARGINPERCENT=10
MINIMUMSTATEFULMARGINABS=200
# Minimum crouton partition size in MB
MINIMUMCROUTONSIZE=500
# Stateful partition size
STATEFULSIZE=2500
STATEFULSIZESET=''
# Crouton partition size
CROUTONSIZE=''
# Which VT to switch to
LOGVT='9'
NOCREATE=''
DELETE=''

USAGE="$APPLICATION [-s size|-c size|-d|-x] [-i number]

Create a separate partition for crouton, immune from accidental wiping when
switching back and forth to developer/normal mode.

This script needs to log the user out, and reboot the system. Make sure no
unsaved document/form is left unsaved.

Under normal circumstances, the stateful partition will not be damaged.
However, it is recommended to backup data as required (Downloads folder,
existing chroots in /usr/local).

$APPLICATION must be run as root.

It is highly recommended to run this from a crosh shell (Ctrl+Alt+T), not VT2.

Basic options:
    -s size     Set the size in megabytes of the stateful partition, the rest
                being allocated to crouton.
                Default: $STATEFULSIZE MB
                Minimum allowed size: $MINIMUMSTATEFULSIZE MB
    -c size     Set the size in megabytes of the crouton partition.
    -d          Delete a partition, and reset the stateful partition to its
                maximum size. The partition to remove is autodetected using its
                label (CROUTON), but it can be specified using '-i number'.
                WARNING: This wipes the content of the crouton partition.

Options for power users only:
    -i number   The partition number to use for crouton. This script will fail
                if the partition exists and is larger than a single sector.
                Default: $CROUTONPARTNUMBER
    -x          Do not create the new partition: only switch off all services,
                switch to VT2, so that the partition layout can be edited
                manually.
"

# Common functions
. "$SCRIPTDIR/installer/functions"

# Process arguments
while getopts 'c:dhi:s:x' f; do
    case "$f" in
    c) CROUTONSIZE="$OPTARG";;
    d) DELETE='y';;
    h) error 2 "$USAGE";;
    i) CROUTONPARTNUMBER="$OPTARG"; CROUTONPARTNUMBERSET='y';;
    s) STATEFULSIZE="$OPTARG"; STATEFULSIZESET='y';;
    x) NOCREATE='y';;
    \?) error 2 "$USAGE";;
    esac
done
shift "$((OPTIND-1))"

if [ ! "$USER" = root -a ! "$UID" = 0 ]; then
    error 2 "$APPLICATION must be run as root."
fi

test="${STATEFULSIZESET}${CROUTONSIZE:+y}${DELETE}${NOCREATE}"
if [ "${#test}" -gt 1 ]; then
    error 2 "Only one of -c, -d, -s and -x can be set.
$USAGE"
fi

if ! [ "$CROUTONPARTNUMBER" -gt 0 ] 2>/dev/null \
        || [ "$CROUTONPARTNUMBER" -gt 128 ]; then
    error 2 "Partition number $CROUTONPARTNUMBER is not valid."
fi

if ! [ "$STATEFULSIZE" -gt 0 ] 2>/dev/null; then
    error 2 "Partition size $STATEFULSIZE is not valid."
fi

if [ -n "$CROUTONSIZE" ] && ! [ "$CROUTONSIZE" -gt 0 ] 2>/dev/null; then
    error 2 "Partition size $CROUTONSIZE is not valid."
fi

# Avoid kernel panics due to slow I/O
disablehungtask

# Set ROOTDEVICE
findrootdevice

updatestatus="`update_engine_client --status 2>/dev/null | \
               sed -n "s/CURRENT_OP=\(.*\)$/\1/p"`"

if [ "$updatestatus" != "UPDATE_STATUS_IDLE" ]; then
    if [ "$updatestatus" = "UPDATE_STATUS_UPDATED_NEED_REBOOT" ]; then
        error 1 "\
A Chromium OS update is currently pending, please restart your Chromebook,
then launch this script again."
    else
        error 1 "\
Chromium OS is currently being updated (status: $updatestatus).
Please wait for the update to complete (it can be monitored with
'update_engine_client --update'), then restart your Chromebook, and launch this
script again."
    fi
fi

# Restore stateful partition to its original size
if [ -n "$DELETE" ]; then
    if [ -z "$CROUTONPARTNUMBERSET" ]; then
        CROUTONPARTNUMBER="`cgpt find -n -l CROUTON "$ROOTDEVICE" || true`"

        if [ -z "$CROUTONPARTNUMBER" ]; then
            error 1 "Cannot find CROUTON partition."
        fi
    fi

    name="`cgpt show -i "$CROUTONPARTNUMBER" -l "$ROOTDEVICE"`"
    name=${name:-unknown}

    # Unit: sectors (512 bytes)
    statestart="`cgpt show -i 1 -b "$ROOTDEVICE"`"
    statesize="`cgpt show -i 1 -s "$ROOTDEVICE"`"
    croutonstart="`cgpt show -i "$CROUTONPARTNUMBER" -b "$ROOTDEVICE"`"
    croutonsize="`cgpt show -i "$CROUTONPARTNUMBER" -s "$ROOTDEVICE"`"
    newstatesize="$((statesize+croutonsize))"

    echo "Stateful partition:"
    cgpt show -i 1 "$ROOTDEVICE"
    echo "'$name' partition:"
    cgpt show -i "$CROUTONPARTNUMBER" "$ROOTDEVICE"

    if [ "$((statestart+statesize))" -ne "$croutonstart" ]; then
        error 1 "Error: stateful and '$name' partitions are not contiguous."
    fi

    echo -n "
WARNING: Removing '$name' partition: ALL DATA ON THAT PARTITION WILL BE LOST.

Type 'delete' if you are sure that you want to do that: "
    if [ -t 0 ]; then
        read -r line
    else
        line="$CROUTON_MKPART_DELETE"
        echo "$line"
    fi
    if [ "$line" != "delete" ]; then
        error 2 "Aborting..."
    fi

    # This could be done without reboot, as resize2fs can be done online.
    # However, Chromium OS cannot re-read the partition table without reboot.
elif [ -z "$NOCREATE" ]; then
    rootc="`cgpt find -n -l ROOT-C "$ROOTDEVICE"`"
    if [ "`cgpt show -i "$rootc" -s "$ROOTDEVICE"`" -gt 1 ]; then
        echo -n "ROOT-C is not empty (did you install ChrUbuntu?).
Using both ChrUbuntu and crouton partition is not recommended, especially if
your total storage space is only 16GB, as the space for each system (Chromium OS
stateful partition, crouton and ChrUbuntu) will be very limited.
Do you still want to continue? [y/N] " 1>&2
        read -r response
        if [ "${response#[Yy]}" = "$response" ]; then
            exit 1
        fi
    fi

    if [ "`cgpt show -i "$CROUTONPARTNUMBER" -s "$ROOTDEVICE"`" -gt 1 ]; then
        echo  "Partition $CROUTONPARTNUMBER already exists:" 1>&2
        cgpt show -i "$CROUTONPARTNUMBER" "$ROOTDEVICE"
        exit 1
    fi

    if cgpt find -n -l CROUTON "$ROOTDEVICE" > /dev/null; then
        error 1 "CROUTON partition already exists."
    fi

    if [ -n "`find $PREFIX/chroots/* \
                        -type d -maxdepth 0 2>/dev/null || true`" ]; then
        echo -n "$PREFIX/chroots is not empty.
It is recommended that you follow the migration guide to transfer existing
chroots to the new partition.
Do you still want to continue? [y/N] " 1>&2
        read -r response
        if [ "${response#[Yy]}" = "$response" ]; then
            exit 1
        fi
    fi

    # All GPT sizes/offsets are expressed in sectors (512 bytes)
    statestart="`cgpt show -i 1 -b "$ROOTDEVICE"`"
    statesize="`cgpt show -i 1 -s "$ROOTDEVICE"`"

    if [ -n "$CROUTONSIZE" ]; then
        STATEFULSIZE="$((statesize/(1024*2)-CROUTONSIZE))"
    fi

    # Make sure the stateful partition can be resized to the requested size
    # Unit: KiB
    statefulallocated="`df -P -k ${ROOTDEVICEPREFIX}1 \
                            | awk 'x{print $3;exit} {x=1}'`"

    if ! [ "$statefulallocated" -gt 0 ] 2>/dev/null; then
        error 2 "Cannot obtain free space on stateful partition."
    fi

    # Unit: MiB
    statefulsafe=$(((statefulallocated+\
                     statefulallocated*MINIMUMSTATEFULMARGINPERCENT/100)/1024))
    statefulsafe2=$((statefulallocated/1024+MINIMUMSTATEFULMARGINABS))
    if [ "$MINIMUMSTATEFULSIZE" -gt "$statefulsafe" ]; then
        statefulsafe="$MINIMUMSTATEFULSIZE"
    fi
    if [ "$statefulsafe2" -gt "$statefulsafe" ]; then
        statefulsafe="$statefulsafe2"
    fi

    if [ "$STATEFULSIZE" -lt "$statefulsafe" ]; then
        error 1 \
"Cannot shrink the stateful partition under $statefulsafe MB (selected size: $STATEFULSIZE MB).
Free up some space, or choose a larger stateful partition size (-s) or smaller
crouton partition (-c)."
    fi

    # Unit: 512 bytes block
    newstatesize="$((STATEFULSIZE*1024*2))"

    if [ "$newstatesize" -gt "$statesize" ]; then
        error 1 "Stateful partition size must be less than the current one ($((statesize/(1024*2))) MB)."
    fi

    croutonsize=$((statesize-newstatesize))
    croutonstart=$((statestart+newstatesize))

    if [ "$croutonsize" -lt "$((MINIMUMCROUTONSIZE*1024*2))" ]; then
        error 1 "You must leave at least $MINIMUMCROUTONSIZE MB for the crouton partition."
    fi

    echo "Overriding partion table entry $CROUTONPARTNUMBER:"
    cgpt show -i "$CROUTONPARTNUMBER" "$ROOTDEVICE"
    echo "----"
    echo "New partition sizes:"
    echo "    Stateful partition (Chromium OS): $((newstatesize/(2*1024))) MB"
    freespace=$((newstatesize/(2*1024)-statefulallocated/1024))
    echo "        Leftover free space: $freespace MB"
    echo "    crouton: $((croutonsize/(2*1024))) MB"
    echo "----"

    echo -n "Type 'yes' if you are you satisfied with these new sizes: "
    if [ -t 0 ]; then
        read -r line
    else
        line="$CROUTON_MKPART_YES"
        echo "$line"
    fi
    if [ "$line" != "yes" ]; then
        error 2 "Aborting..."
    fi
fi

if grep -q '^[^ ]* '"`readlink -m '/var/run/crouton'`/" /proc/mounts \
        || grep -q '^[^ ]* '"$PREFIX"'/chroots' /proc/mounts; then
    error 1 \
"Some chroots are mounted. Log out from these, and run this script again."
fi

echo "====== WARNING ======"
if [ -n "$DELETE" ]; then
    echo "This script will now log you off and wipe '$name' (${ROOTDEVICEPREFIX}$CROUTONPARTNUMBER)."
elif [ -z "$NOCREATE" ]; then
    echo "This script will now log you off, setup the crouton partition, and reboot."
else
    echo "This script will now log you off and unmount the stateful partition."
fi
echo "Make sure all your current work is saved."

time=10
while [ "$time" -gt 0 ]; do
    printf "\\rYou have %2d seconds to press Ctrl-C to abort..." "$time"
    sleep 1
    time="$((time-1))"
done
echo

# Unmount crouton partition, if it exists
if [ -n "$DELETE" -o -n "$NOCREATE" ]; then
    for mountpoint in `awk \
            '$1 == "'"${ROOTDEVICEPREFIX}$CROUTONPARTNUMBER"'" { print $2 }' \
            /proc/mounts`; do
        if ! umount "$mountpoint"; then
            error 1 \
"Cannot unmount partition in '$mountpoint', make sure nothing is using it."
        fi
    done
fi

( # Fork a subshell, with input/output in VT $LOGVT
    clear || true

    # Redefine error function
    error() {
        local ecode="$1"
        shift
        chvt $LOGVT
        echo "$*" 1>&2
        echo "Press enter to reboot..."
        sync
        ( sleep 30; reboot ) &
        read -r line
        settrap ""
        reboot
        exit "$ecode" # unreachable
    }

    addtrap "chvt $LOGVT; echo 'Something went wrong, press enter to reboot.'; \
             sync; ( sleep 30; reboot ) & read -r line; \
             echo 'Rebooting...'; reboot"

    # Make sure screen does not blank out (setterm does not work in this
    # context: send control sequence instead)
    /bin/echo -n -e "\x1b[9;0]\x1b[14;0]"

    # Get out of the stateful partition
    cd /

    echo "Logging user out..."
    dbus-send --system --dest=org.chromium.SessionManager --type=method_call \
        --print-reply /org/chromium/SessionManager \
        org.chromium.SessionManagerInterface.StopSession \
        string:"crouton installer"

    # Detect when the user has been logged out (1 minute timeout)
    tries=12
    while [ "$tries" -gt 0 ] && grep -q '^/home/.shadow' /proc/mounts; do
        chvt $LOGVT
        echo "Waiting for logout to complete..."
        sleep 5
        # After 30s, be more forceful
        if [ "$tries" -le 6 ]; then
            echo "Some mounts are still active:"
            grep '^/home/.shadow' /proc/mounts || true
            echo "Trying to unmount..."
            grep '^/home/.shadow' /proc/mounts | cut -f1 -d ' ' \
		| xargs --no-run-if-empty -d '
' -n 50 umount || true
        fi
        tries="$((tries-1))"
    done

    # Switch to log VT
    chvt $LOGVT

    if [ "$tries" = 0 ]; then
        error 1 "Cannot log user out. Your system has not been modified."
    fi

    echo "Stopping all services..."

    # Stop all services except tty2. || true is needed as sometimes services
    # stop dependencies before we can stop them ourselves.
    initctl list | grep process | cut -f1 -d' ' | grep -v tty2 | \
            xargs -I{} stop {} || true

    # Make sure we stay on the right VT (some services switch VT when stopped)
    chvt $LOGVT

    echo "Unmounting stateful partition..."
    # Try to unmount directories where ${ROOTDEVICEPREFIX}1 and
    # /dev/mapper/encstateful are mounted. Order by length so that
    # subdirectories are removed first.
    for device in "/dev/mapper/encstateful" "${ROOTDEVICEPREFIX}1"; do
        echo "Unmounting $device..."
        for path in `awk '
                    $1 == "'"$device"'" {
                        sub(/\\\\040\(deleted\)$/, "", $2)
                        print length($2)":"$2
                    }' /proc/mounts | sort -nr | cut -d: -f 2`; do
            echo "Unmounting $path and subdirectories..."
            for mnt in `awk '
                            $2 ~ "^'"$path"'($|/)" {
                                sub(/\\\\040\(deleted\)$/, "", $2)
                                print length($2)":"$2
                            }' /proc/mounts | sort -nr | cut -d: -f 2`; do
		# Replace \040 by space
		mnt="`echo -n "$mnt" | sed -e 's/\\\\040/ /g'`"
                pid="`lsof -t +D "$mnt" || true`"
                if [ -n "$pid" ]; then
                    # These processes should have terminated already, KILL them
                    echo "Killing processes in $mnt..."
                    kill -9 $pid || true
                fi
                echo "Unmounting $mnt..."
                umount "$mnt" 2>/dev/null
            done
        done

        if [ "$device" = "/dev/mapper/encstateful" ]; then
            dmsetup remove "/dev/mapper/encstateful" 2>/dev/null
            losetup -D 2>/dev/null
        fi
    done

    # Just in case, really.
    chvt $LOGVT

    if grep -q "^${ROOTDEVICEPREFIX}1" /proc/mounts; then
        error 1 "Cannot unmount stateful partition. Your system has not been modified."
    fi

    if [ -n "$NOCREATE" ]; then
        echo "Services were stopped, and stateful partition is unmounted."
        echo "Press enter to switch back to VT2 (this is VT$LOGVT)."
        echo "Then login as root, and type reboot when you are done."
        read -r line
        sync
        chvt 2
        settrap ""
        exit 0
    fi

    # For each partition table change, call partx on the relevant partition
    # number to update the kernel view
    if [ -n "$DELETE" ]; then
        echo "Removing partition $CROUTONPARTNUMBER..."
        cgpt add -i "$CROUTONPARTNUMBER" -b 0 -s 1 -l "" -t unused "$ROOTDEVICE"
        partx -v -d "$CROUTONPARTNUMBER" "$ROOTDEVICE"

        echo "Resizing stateful partition..."
        cgpt add -i 1 -s "$newstatesize" "$ROOTDEVICE"
        partx -v -u 1 "$ROOTDEVICE"

        # Resize the stateful partition
        e2fsck -f -p "${ROOTDEVICEPREFIX}1"
        resize2fs -p "${ROOTDEVICEPREFIX}1"
    else
        echo "Resizing stateful partition..."
        e2fsck -f -p "${ROOTDEVICEPREFIX}1"
        resize2fs -p "${ROOTDEVICEPREFIX}1" "${newstatesize}s"

        echo "Updating partition table..."
        cgpt add -i 1 -b "$statestart" -s "$newstatesize" -l STATE "$ROOTDEVICE"
        partx -v -u 1 "$ROOTDEVICE"

        cgpt add -i "$CROUTONPARTNUMBER" -t data \
                 -b "$croutonstart" -s "$croutonsize" -l CROUTON "$ROOTDEVICE"
        partx -v -a "$CROUTONPARTNUMBER" "$ROOTDEVICE"

        echo "Formatting crouton partition..."
        mkfs.ext4 "${ROOTDEVICEPREFIX}${CROUTONPARTNUMBER}"
    fi

    sync

    echo "New partition table:"
    cgpt show "$ROOTDEVICE" -i 1
    cgpt show "$ROOTDEVICE" -i "$CROUTONPARTNUMBER"

    echo "Success! Press enter to reboot..."
    sync
    ( sleep 30; reboot ) &
    read -r line
    settrap ""
    reboot
) >"/dev/tty$LOGVT" 2>&1 <"/dev/tty$LOGVT" &

wait

error 1 "Cannot start subshell."
