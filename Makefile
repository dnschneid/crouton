# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

TARGET = crouton
WRAPPER = build/wrapper.sh
SCRIPTS := \
	$(wildcard chroot-bin/*) \
	$(wildcard chroot-etc/*) \
	$(wildcard host-bin/*) \
	$(wildcard installer/*.sh) installer/functions \
	$(wildcard installer/*/*) \
	$(wildcard src/*) \
	$(wildcard targets/*)
GENVERSION = build/genversion.sh
VERSION = 0
TARPARAMS ?= -j

$(TARGET): $(WRAPPER) $(SCRIPTS) $(GENVERSION) Makefile
	{ \
		sed -e "s/\$$TARPARAMS/$(TARPARAMS)/" \
			-e "s/VERSION=.*/VERSION='$(shell $(GENVERSION) $(VERSION))'/" \
			$(WRAPPER) \
		&& tar --owner=root --group=root -c $(TARPARAMS) $(SCRIPTS) \
		&& chmod +x /dev/stdout \
	;} > $(TARGET) || ! rm -f $(TARGET)

croutoncursor: src/cursor.c Makefile
	gcc -g -Wall -Werror src/cursor.c -lX11 -lXfixes -lXrender -o croutoncursor

croutonxi2event: src/xi2event.c Makefile
	gcc -g -Wall -Werror src/xi2event.c -lX11 -lXi -o croutonxi2event

clean:
	rm -f $(TARGET) croutoncursor croutonxi2event

.PHONY: clean
