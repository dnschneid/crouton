#!/bin/sh
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This is an simple script using enter-chroot.sh to start an Xfce session.
# You should enter the chroot and install xfce before running this.
#    sudo apt-get install xfce4 xfce4-goodies shimmer-themes
# (xfce4-goodies and shimmer-themes are optional.)

exec "${0%/*}/enter-chroot.sh" "${1:-precise}" 1000 startxfce4
