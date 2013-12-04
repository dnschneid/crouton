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

ifeq ($(wildcard .git/HEAD),)
    GITHEAD :=
else
    GITHEADFILE := .git/refs/heads/$(shell cut -d/ -f3 '.git/HEAD')
    ifeq ($(wildcard $(GITHEADFILE)),)
        GITHEAD := .git/HEAD
    else
        GITHEAD := .git/HEAD .git/refs/heads/$(shell cut -d/ -f3 '.git/HEAD')
    endif
endif


$(TARGET): $(WRAPPER) $(SCRIPTS) $(GENVERSION) $(GITHEAD) Makefile
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

croutonvtmonitor: src/vtmonitor.c Makefile
	gcc -g -Wall -Werror src/vtmonitor.c -o croutonvtmonitor

croutonwebsocket: src/websocket.c Makefile
	gcc -g -Wall -Werror src/websocket.c -o croutonwebsocket

clean:
	rm -f $(TARGET) croutoncursor croutonxi2event croutonvtmonitor croutonwebsocket

.PHONY: clean
