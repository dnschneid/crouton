#!/bin/sh -e
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

if [ $# = 0 ]; then
    echo "Usage: %{0##*/} user@hostname [release]" 1>&2
    echo "${0##*/} requires SSH access to a Debian-based system to boostrap." 1>&2
    exit 2
fi
if [ ! "$USER" = root -a ! "$UID" = 0 ]; then
    echo "${0##*/} must be run as root." 1>&2
    exit 2
fi

RELEASE="${2:-precise}"
MIRROR='http://archive.ubuntu.com/ubuntu/'

ARCH="`uname -m | sed -e 's/x86_64/amd64/' -e 's/arm.*/arm/'`"

CHROOT="$RELEASE"
if grep -q 'CHROMEOS' '/etc/lsb-release'; then
    DESTDIR="/usr/local"
else
    DESTDIR="chroot"
fi

echo "Installing $RELEASE chroot to $DESTDIR/$CHROOT" 1>&2
if [ ! -w "$DESTDIR" ]; then
    echo "You do not have write access to $DESTDIR." 1>&2
    exit 2
fi
mkdir -p "$DESTDIR"
oldpwd="$PWD"
cd "$DESTDIR"

echo "Bootstrapping using ssh $1" 1>&2

tmp="`mktemp --tmpdir=/tmp make-chroot.XXX`"
trap "rm -f \"$tmp\"" INT HUP 0

while true; do
ssh $1 sh -ec \''
if ! hash debootstrap; then
    echo 'needsinstall'
    exit
fi
tmp="`mktemp -d --tmpdir=/tmp make-chroot.XXX`"
trap "rm -rf \"$tmp\"" INT HUP 0
cd "$tmp"
fakeroot debootstrap --foreign --arch="'"$ARCH"'" "'"$RELEASE"'" "'"$CHROOT"'" "'"$MIRROR"'" 1>&2
echo -n "Compressing and downloading chroot environment..." 1>&2
fakeroot tar --checkpoint=100 --checkpoint-action=exec="echo -n . 1>&2" -cajf- "'"$CHROOT"'"
'\' > "$tmp"

if head -n 1 "$tmp" | grep -q needsinstall; then
    echo 'debootstrap must be installed to prepare the chroot environment.' 1>&2
    ssh -t $1 sudo apt-get install debootstrap
else
    break
fi
done

echo 'done' 1>&2
echo 'Unpacking chroot environment...' 1>&2
tar -xf "$tmp"
rm -f "$tmp"
trap - INT HUP 0

echo 'Preparing chroot environment...' 1>&2
echo -n 'Specify a new user: ' 1>&2
read user junk
enterchroot="${0%/*}/enter-chroot.sh"
preparescript="$CHROOT/prepare-chroot.sh"
cat > "$preparescript" <<EOF
#!/bin/sh -e
export PATH='/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin'

[ -r /debootstrap ] && /debootstrap/debootstrap --second-stage
dpkg-reconfigure tzdata
if ! grep -q "^$user" /etc/sudoers; then
    adduser "$user" && echo "$user ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi

echo 'Preparing software sources' 1>&2
cat > /etc/apt/sources.list <<EOFEOF
deb $MIRROR $RELEASE main restricted universe multiverse
deb-src $MIRROR $RELEASE main restricted universe multiverse
deb $MIRROR $RELEASE-updates main restricted universe multiverse
deb-src $MIRROR $RELEASE-updates main restricted universe multiverse
deb $MIRROR $RELEASE-security main restricted universe multiverse
deb-src $MIRROR $RELEASE-security main restricted universe multiverse
EOFEOF
apt-get -y update

echo 'Ensuring system is up-to-date' 1>&2
apt-get -y upgrade

echo 'Installing additional packages' 1>&2
apt-get -y install wget openssh-client xorg gdebi chromium-browser
# Fix launching X11 from inside crosh
sed -i 's/allowed_users=.*/allowed_users=anybody/' '/etc/X11/Xwrapper.config'
# Ensure X always starts on display :1
cat > /usr/local/bin/xinit <<EOFEOF
#!/bin/sh
dash=--
for x in "\\\$@"; do
    if [ "\\\$x" = -- ]; then
        dash=
        break
    fi
done
exec /usr/bin/xinit "\\\$@" \\\$dash :1
EOFEOF
chmod a+rx /usr/local/bin/xinit
# Add a blank Xauthority
touch /home/$user/.Xauthority
chown $user:$user /home/$user/.Xauthority
chmod 600 /home/$user/.Xauthority
# Set sudo mode for gksu
su - $user -c 'gconftool -t b -s /apps/gksu/sudo-mode t'

echo 'You do not yet have a desktop environment installed.' 1>&2
echo -n 'Would you like to install Xfce? [y/N] '
read response junk
if [ "\$response" = y -o "\$response" = yes ]; then
    apt-get -y install xfce4 xfce4-goodies shimmer-themes dictionaries-common-
fi

echo 'Cleaning up' 1>&2
apt-get clean
rm "\$0"
EOF
chmod +x "$preparescript"
cd "$oldpwd"
while ! "$enterchroot" "$CHROOT" "/${preparescript##*/}"; do
    echo "Running /${preparescript##*/} inside the chroot failed." 1>&2
    echo "Will re-attempt in 5 seconds, or you can ctrl-C and run it yourself." 1>&2
    echo "This is the last step in setting up the chroot." 1>&2
    sleep 5
done

echo "Done! You can enter the chroot using $enterchroot $CHROOT" 1>&2
echo "If you installed Xfce, you can quickly start it from outside the chroot" 1>&2
echo "by running ${0%/*}/startxfce4.sh" 1>&2
