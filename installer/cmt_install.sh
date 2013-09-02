#!/bin/sh
#
# to be run from inside the chroot as sudo

CROUTON_CMT=~/Downloads/.crouton_cmt
cd $CROUTON_CMT
cp -vd lib/* /usr/lib
if [ ! -d /usr/lib/xorg/modules/input/backup ]; then
  mkdir -p /usr/lib/xorg/modules/input/backup
  cp -d /usr/lib/xorg/modules/input/* /usr/lib/xorg/modules/input/backup
fi
cp -vd input/cmt_drv.so /usr/lib/xorg/modules/input
mkdir -p /etc/X11/xorg.conf.d
cp -rvd X11/xorg.conf.d/50* /etc/X11/xorg.conf.d
