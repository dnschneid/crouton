# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

TARGET = crouton
TARGETTMP = .$(TARGET).tmp
WRAPPER = build/wrapper.sh
SCRIPTS := \
	$(wildcard chroot-bin/*) \
	$(wildcard host-bin/*) \
	$(wildcard installer/*) \
	$(wildcard targets/*)
VERSION = '0-%Y%m%d%H%M%S'
TARPARAMS ?= -j

$(TARGET): $(WRAPPER) $(SCRIPTS) Makefile
	sed -e "s/\$$TARPARAMS/$(TARPARAMS)/" \
		-e "s/VERSION=.*/VERSION='$(shell date +$(VERSION))'/" \
		$(WRAPPER) > $(TARGETTMP)
	tar --owner=root --group=root -c $(TARPARAMS) $(SCRIPTS) >> $(TARGETTMP)
	chmod +x $(TARGETTMP)
	mv -f $(TARGETTMP) $(TARGET)

clean:
	rm -f $(TARGETTMP) $(TARGET)

.PHONY: clean
