/* Copyright (c) 2016 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * LD_PRELOAD hack to make Xorg happy in a system without VT-switching.
 * gcc -shared -fPIC -ldrm -ldl -I/usr/include/libdrm -Wall -O2 freon.c -o croutonfreon.so
 *
 * Powered by black magic.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <string.h>
#include <stdarg.h>
#include <stdlib.h>
#include <unistd.h>
#include <linux/input.h>
#include <linux/vt.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#define LOCK_FILE_DIR "/tmp/crouton-lock"
#define DISPLAY_LOCK_FILE LOCK_FILE_DIR "/display"
#define LIBCROSSERVICE_METHOD_CALL(function) \
    system("host-dbus dbus-send --system --dest=org.chromium.LibCrosService " \
           "--type=method_call --print-reply /org/chromium/LibCrosService " \
           "org.chromium.LibCrosServiceInterface." #function)
#define DISPLAYSERVICE_METHOD_CALL(function) \
    system("host-dbus dbus-send --system --dest=org.chromium.DisplayService " \
           "--type=method_call --print-reply /org/chromium/DisplayService " \
           "org.chromium.DisplayServiceInterface." #function)

#define TRACE(...) /* fprintf(stderr, __VA_ARGS__) */
#define ERROR(...) fprintf(stderr, __VA_ARGS__)

static int tty0fd = -1;
static int tty7fd = -1;
static int lockfd = -1;

static int (*orig_ioctl)(int d, int request, void* data);
static int (*orig_open)(const char *pathname, int flags, mode_t mode);
static int (*orig_open64)(const char *pathname, int flags, mode_t mode);
static int (*orig_close)(int fd);

static void preload_init() {
    orig_ioctl = dlsym(RTLD_NEXT, "ioctl");
    orig_open = dlsym(RTLD_NEXT, "open");
    orig_open64 = dlsym(RTLD_NEXT, "open64");
    orig_close = dlsym(RTLD_NEXT, "close");
}

/* Grabs the system-wide lockfile that arbitrates which chroot is using the GPU.
 *
 * pid should be either the pid of the process that owns the GPU (eg. getpid()),
 * or 0 to indicate that Chromium OS now owns the GPU.
 *
 * Returns 0 on success, or -1 on error.
 */
static int set_display_lock(unsigned int pid) {
    if (lockfd == -1) {
        if (pid == 0) {
            ERROR("No display lock to release.\n");
            return 0;
        }
        lockfd = orig_open(DISPLAY_LOCK_FILE, O_CREAT | O_WRONLY, 0666);
        if (lockfd == -1) {
            ERROR("Unable to open display lock file.\n");
            return -1;
        }
        if (flock(lockfd, LOCK_EX) == -1) {
            ERROR("Unable to lock display lock file.\n");
            return -1;
        }
    }
    if (ftruncate(lockfd, 0) == -1) {
        ERROR("Unable to truncate display lock file.\n");
        return -1;
    }
    char buf[11];
    int len;
    if ((len = snprintf(buf, sizeof(buf), "%u\n", pid)) < 0) {
        ERROR("pid sprintf failed.\n");
        return -1;
    }
    if (write(lockfd, buf, len) == -1) {
        ERROR("Unable to write to display lock file.\n");
        return -1;
    }
    if (pid == 0) {
        int ret = orig_close(lockfd);
        lockfd = -1;
        if (ret == -1) {
            ERROR("Failure when closing display lock file.\n");
        }
        return ret;
    }
    return 0;
}

static int32_t crtc_set_prop(int fd, uint32_t crtc_id,
			     drmModeObjectPropertiesPtr props,
			     const char *name, uint64_t value)
{
    uint32_t u;
    int32_t ret;
    drmModePropertyPtr prop;

    for (u = 0; u < props->count_props; u++) {
        prop = drmModeGetProperty(fd, props->props[u]);
	if (!prop)
	    continue;
	if (strcmp(prop->name, name)) {
	    drmModeFreeProperty(prop);
	    continue;
	}
	ret = drmModeObjectSetProperty(fd, crtc_id, DRM_MODE_OBJECT_CRTC,
                                       props->props[u], value);
	if (ret < 0)
	    TRACE("setting property %s failed with %d\n", name, ret);
	else
	    ret = 0;
	drmModeFreeProperty(prop);
	return ret;
    }
    TRACE("could not find property %s\n", name);
    return -1;
}

/* Reset CTM/GAMMA properties to avoid artifacts (#3791). */
static void drm_reset_props()
{
    int i, fd;
    drmModeRes* resources;

    if (!orig_open) preload_init();

    fd = orig_open("/dev/dri/card0", O_RDWR, 0);

    TRACE("%s %d\n", __func__, fd);

    if (fd < 0)
        return;

    resources = drmModeGetResources(fd);
    TRACE("%s res=%p\n", __func__, resources);
    if (!resources)
        goto closefd;

    for (i = 0; i < resources->count_crtcs; i++) {
        drmModeObjectPropertiesPtr crtc_props;
	uint32_t crtc_id = resources->crtcs[i];

	crtc_props = drmModeObjectGetProperties(fd, crtc_id, DRM_MODE_OBJECT_CRTC);
	TRACE("%s crtc %d %p\n", __func__, i, crtc_props);
	if (!crtc_props)
            continue;

        /* Reset color matrix to identity and gamma/degamma LUTs to pass through,
         * ignore errors in case they are not supported.
         * ref: https://chromium.googlesource.com/chromiumos/platform/frecon/+/master/drm.c
         */
        crtc_set_prop(fd, crtc_id, crtc_props, "CTM", 0);
        crtc_set_prop(fd, crtc_id, crtc_props, "DEGAMMA_LUT", 0);
        crtc_set_prop(fd, crtc_id, crtc_props, "GAMMA_LUT", 0);

        drmModeFreeObjectProperties(crtc_props);
    }

    drmModeFreeResources(resources);

closefd:
    orig_close(fd);
}

/* Prevents some glitch if Chromium OS keeps cursor enabled (#2878). */
static void drm_disable_cursor()
{
    int i, fd;
    drmModeRes* resources;

    if (!orig_open) preload_init();

    fd = orig_open("/dev/dri/card0", O_RDWR, 0);

    TRACE("%s %d\n", __func__, fd);

    if (fd < 0)
        return;

    resources = drmModeGetResources(fd);
    if (!resources)
        goto closefd;

    TRACE("%s res=%p\n", __func__, resources);
    for (i = 0; i < resources->count_crtcs; i++) {
        drmModeCrtc* crtc;

        crtc = drmModeGetCrtc(fd, resources->crtcs[i]);
        TRACE("%s crtc %d %p\n", __func__, i, crtc);
        if (crtc) {
            drmModeSetCursor(fd, crtc->crtc_id,
                             0, 0, 0);
            drmModeFreeCrtc(crtc);
        }
    }

    drmModeFreeResources(resources);

closefd:
    orig_close(fd);
}

int ioctl(int fd, unsigned long int request, ...) {
    if (!orig_ioctl) preload_init();

    int ret = 0;
    va_list argp;
    va_start(argp, request);
    void* data = va_arg(argp, void*);

    if (fd == tty0fd) {
        TRACE("ioctl tty0 %d %lx %p\n", fd, request, data);
        if (request == VT_OPENQRY) {
            TRACE("OPEN\n");
            *(int*)data = 7;
        }
        ret = 0;
    } else if (fd == tty7fd) {
        TRACE("ioctl tty7 %d %lx %p\n", fd, request, data);
        if (request == VT_GETSTATE) {
            TRACE("STATE\n");
            struct vt_stat* stat = data;
            stat->v_active = 0;
        }

        if ((request == VT_RELDISP && (uintptr_t)data == 1) ||
            (request == VT_ACTIVATE && (uintptr_t)data == 0)) {
            if (lockfd != -1) {
                drm_reset_props();
                TRACE("Telling Chromium OS to regain control\n");
                ret = LIBCROSSERVICE_METHOD_CALL(TakeDisplayOwnership);
                if (WEXITSTATUS(ret) == 1) {
                    ret = DISPLAYSERVICE_METHOD_CALL(TakeOwnership);
                }
                if (set_display_lock(0) < 0) {
                    ERROR("Failed to release display lock\n");
                }
            }
        } else if ((request == VT_RELDISP && (uintptr_t)data == 2) ||
                   (request == VT_ACTIVATE && (uintptr_t)data == 7)) {
            if (set_display_lock(getpid()) == 0) {
                TRACE("Telling Chromium OS to drop control\n");
                ret = LIBCROSSERVICE_METHOD_CALL(ReleaseDisplayOwnership);
                if (WEXITSTATUS(ret) == 1) {
                    ret = DISPLAYSERVICE_METHOD_CALL(ReleaseOwnership);
                }
            } else {
                ERROR("Unable to claim display lock\n");
                ret = -1;
            }
            drm_disable_cursor();
        } else {
            ret = 0;
        }
    } else {
        if (request == EVIOCGRAB) {
            TRACE("ioctl GRAB %d %lx %p\n", fd, request, data);
            /* Driver requested a grab: assume we have it already and report
             * success */
            ret = 0;
        } else {
            ret = orig_ioctl(fd, request, data);
        }
    }
    va_end(argp);
    return ret;
}

static int _open(int (*origfunc)(const char *pathname, int flags, mode_t mode),
                 const char *origname, const char *pathname, int flags, mode_t mode) {
    TRACE("%s %s\n", origname, pathname);
    if (!strcmp(pathname, "/dev/tty0")) {
        tty0fd = origfunc("/dev/null", flags, mode);
        return tty0fd;
    } else if (!strcmp(pathname, "/dev/tty7")) {
        tty7fd = origfunc("/dev/null", flags, mode);
        return tty7fd;
    } else {
        const char* event = "/dev/input/event";
        int fd = origfunc(pathname, flags, mode);
        TRACE("%s %s %d\n", origname, pathname, fd);
        if (!strncmp(pathname, event, strlen(event))) {
            TRACE("GRAB\n");
            orig_ioctl(fd, EVIOCGRAB, (void *) 1);
        }
        return fd;
    }
}

int open(const char *pathname, int flags, ...) {
    if (!orig_open) preload_init();

    va_list argp;
    va_start(argp, flags);
    mode_t mode = va_arg(argp, mode_t);
    va_end(argp);

    return _open(orig_open, "open", pathname, flags, mode);
}

int open64(const char *pathname, int flags, ...) {
    if (!orig_open64) preload_init();

    va_list argp;
    va_start(argp, flags);
    mode_t mode = va_arg(argp, mode_t);
    va_end(argp);

    return _open(orig_open64, "open64", pathname, flags, mode);
}

int close(int fd) {
    if (!orig_close) preload_init();

    TRACE("close %d\n", fd);

    if (fd == tty0fd) {
        tty0fd = -1;
    } else if (fd == tty7fd) {
        tty7fd = -1;
    }
    return orig_close(fd);
}

uid_t getuid0(void) {
    TRACE("getuid0\n");
    return 0;
}
