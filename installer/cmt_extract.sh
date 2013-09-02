#!/bin/sh
#
# to be run from inside crosh as chronos

CROUTON_CMT=~/Downloads/.crouton_cmt
mkdir -p $CROUTON_CMT/lib
cp -d /usr/lib64/libgestures* $CROUTON_CMT/lib
cp -d /usr/lib64/libevdev* $CROUTON_CMT/lib
cp -d /usr/lib64/libbase-core-180609* $CROUTON_CMT/lib
mkdir -p $CROUTON_CMT/input
cp -d /usr/lib64/xorg/modules/input/*.so $CROUTON_CMT/input
mkdir -p $CROUTON_CMT/X11
cp -dr /etc/X11/xorg.conf.d $CROUTON_CMT/X11
