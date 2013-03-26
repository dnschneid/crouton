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
	$(wildcard src/*) \
	$(wildcard targets/*)
GENVERSION = build/genversion.sh
VERSION = 0
TARPARAMS ?= -j

$(TARGET): $(WRAPPER) $(SCRIPTS) $(GENVERSION) Makefile
	sed -e "s/\$$TARPARAMS/$(TARPARAMS)/" \
		-e "s/VERSION=.*/VERSION='$(shell $(GENVERSION) $(VERSION))'/" \
		$(WRAPPER) > $(TARGETTMP)
	tar --owner=root --group=root -c $(TARPARAMS) $(SCRIPTS) >> $(TARGETTMP)
	chmod +x $(TARGETTMP)
	mv -f $(TARGETTMP) $(TARGET)

croutoncursor: src/cursor.c Makefile
	gcc -g -Wall -Werror src/cursor.c -lX11 -lXfixes -lXrender -o croutoncursor

croutonticks: src/ticks.c Makefile
	gcc -g -Wall -Werror src/ticks.c -lrt -o croutonticks

clean:
	rm -f $(TARGETTMP) $(TARGET) croutoncursor croutonticks

.PHONY: clean
