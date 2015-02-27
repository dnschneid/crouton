/* Copyright (c) 2015 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * LD_PRELOAD hack to make Xorg happy in a system with the vgem device enabled.
 * gcc -shared -fPIC  -ldl -Wall -O2 xorg.c -o croutonxorg.so
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>

#define TRACE(...) /* fprintf(stderr, __VA_ARGS__) */

static int (*orig_udev_sysname)(void *udev_enumerate, const char *sysname);

static void preload_init() {
    orig_udev_sysname = dlsym(RTLD_NEXT, "udev_enumerate_add_match_sysname");
}

int udev_enumerate_add_match_sysname(void *udev_enum, const char *sysname) {
    if (!orig_udev_sysname) preload_init();
    TRACE("udev_enumerate_add_match_sysname '%s'\n", sysname);
    if (sysname && !strcmp(sysname, "card[0-9]*")) {
        sysname = "card0";
    }
    return orig_udev_sysname(udev_enum, sysname);
}
