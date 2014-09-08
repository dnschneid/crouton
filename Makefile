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
HEADS = .git/refs/heads
VERSION = 1
TARPARAMS ?= -j

croutoncursor_LIBS = -lX11 -lXfixes -lXrender
croutonwmtools_LIBS = -lX11
croutonxi2event_LIBS = -lX11 -lXi

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

$(SRCTARGETS): src/$(patsubst crouton%,src/%.c,$@) Makefile
	gcc -g -Wall -Werror $(patsubst crouton%,src/%.c,$@) $($@_LIBS) -o $@

extension: $(EXTTARGET)

$(CONTRIBUTORS): $(HEADS)/master $(CONTRIBUTORSSED)
	git shortlog -s | sed -f $(CONTRIBUTORSSED) | sort -u > $(CONTRIBUTORS)

contributors: $(CONTRIBUTORS)

all: $(TARGET) $(SRCTARGETS) $(EXTTARGET)

clean:
	rm -f $(TARGET) $(EXTTARGET) $(SRCTARGETS)

.PHONY: all clean contributors extension
