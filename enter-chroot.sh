#!/bin/sh -e
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

if [ "$1" = -h -o "$1" = --help ]; then
    echo "Usage: ${0##*/} [chroot-label [command [args...]]]" 1>&2
    echo "       ${0##*/} chroot-label UID \"command [args...]\"" 1>&2
    exit 2
fi

CHROOT="/usr/local/${1:-precise}"
[ "$#" = 0 ] || shift

if [ ! "$USER" = root -a ! "$UID" = 0 ]; then
    echo "${0##*/} must be run as root."
    exit 2
fi

cd "$CHROOT"

# Did we specify a UID on the command line?
case "$1" in
    ''|*[!0-9]*) cmd=;;
     *) cmd='su - '"`awk -F: '$3=='"$1"'{print $1}' etc/passwd`"
        shift
        [ "$#" = 0 ] || cmd="$cmd -c";;
esac

# Ensure the chroot is executable and writable
mp="$CHROOT"
while ! mountpoint -q "$mp"; do
    mp="${mp%/*}"
    [ -z "$mp" ] && mp=/
done
mount -o remount,rw,dev,exec "$mp"
unset mp

# Prepare chroot filesystem
# Soft-link resolv.conf so that updates are automatically propagated
mkdir -p etc/host-shill
ln -sf host-shill/resolv.conf etc/resolv.conf
# Mounts; will auto-unmount when the script exits
umount='umount etc/host-shill proc dev/pts sys tmp 2>/dev/null || { sleep 5; umount dev 2>/dev/null; } || true'
trap "$umount" 0
mount --bind /var/run/shill etc/host-shill
mount --bind /proc proc
mount --bind /dev dev
mount --bind /sys sys
mount --bind /tmp tmp
mount -t devpts none dev/pts

# Fix launching chrome/chromium
chmod 1777 dev/shm

# Disable screen dimming (TODO: daemon script to poke it instead)
initctl stop powerd 2>/dev/null || nopowerd=1

# Start the chroot and any specified command
{ env -i TERM="$TERM" chroot . $cmd "$@"; ret=$?; } || true

# Post-run; clean up
[ "$nopowerd" ] || initctl start powerd
eval "$umount"
exit $ret
