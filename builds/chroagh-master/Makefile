# Copyright (c) 2014 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

TARGET = crouton
EXTTARGET = crouton.zip
SRCTARGETS = $(patsubst src/%.c,crouton%,$(wildcard src/*.c))
CONTRIBUTORS = CONTRIBUTORS
WRAPPER = build/wrapper.sh
SCRIPTS := \
	$(wildcard chroot-bin/*) \
	$(wildcard chroot-etc/*) \
	$(wildcard host-bin/*) \
	$(wildcard installer/*.sh) installer/functions \
	$(wildcard installer/*/*) \
	$(wildcard src/*) \
	$(wildcard targets/*)
EXTSOURCES = $(wildcard host-ext/crouton/*)
GENVERSION = build/genversion.sh
CONTRIBUTORSSED = build/CONTRIBUTORS.sed
RELEASE = build/release.sh
VERSION = 1
TARPARAMS ?= -j

CFLAGS=-g -Wall -Werror -Os

croutoncursor_LIBS = -lX11 -lXfixes -lXrender
croutonfbserver_LIBS = -lX11 -lXdamage -lXext -lXfixes -lXtst
croutonwmtools_LIBS = -lX11
croutonxi2event_LIBS = -lX11 -lXi

croutonwebsocket_DEPS = src/websocket.h
croutonfbserver_DEPS = src/websocket.h

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

$(EXTTARGET): $(EXTSOURCES) Makefile
	rm -f $(EXTTARGET) && zip -q --junk-paths $(EXTTARGET) $(EXTSOURCES)

$(SRCTARGETS): src/$(patsubst crouton%,src/%.c,$@) $($@_DEPS) Makefile
	gcc $(CFLAGS) $(patsubst crouton%,src/%.c,$@) $($@_LIBS) -o $@

extension: $(EXTTARGET)

$(CONTRIBUTORS): $(GITHEAD) $(CONTRIBUTORSSED)
	git shortlog -s | sed -f $(CONTRIBUTORSSED) | sort -u > $(CONTRIBUTORS)

contributors: $(CONTRIBUTORS)

release: $(CONTRIBUTORS) $(TARGET) $(RELEASE)
	[ ! -d .git ] || git status | grep -q 'working directory clean' || \
		{ echo "There are uncommitted changes. Aborting!" 1>&2; exit 2; }
	$(RELEASE) $(TARGET)

force-release: $(CONTRIBUTORS) $(TARGET) $(RELEASE)
	$(RELEASE) -f $(TARGET)

all: $(TARGET) $(SRCTARGETS) $(EXTTARGET)

clean:
	rm -f $(TARGET) $(EXTTARGET) $(SRCTARGETS)

.PHONY: all clean contributors extension release force-release
