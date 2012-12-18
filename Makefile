# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

TARGET=crouton.tar.bz2
SCRIPTS=enter-chroot.sh make-chroot.sh startxfce4.sh


$(TARGET): $(SCRIPTS) Makefile
	tar --owner=root --group=root --mode=a=rx,u+w -cjf $(TARGET) $(SCRIPTS)
