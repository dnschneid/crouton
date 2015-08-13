/* Copyright (c) 2015 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Monitors the specified X11 server for cursor change events, and copies the
 * cursor image over to the X11 server specified in DISPLAY.
 */

#include <X11/Xlib.h>
#include <X11/extensions/Xrender.h>
#include <X11/extensions/Xfixes.h>
#include <stdio.h>

static int error = 0;

static int error_handler(Display *d, XErrorEvent *e) {
    fprintf(stderr, "X11 error: %d, %d, %d\n",
            e->error_code, e->request_code, e->minor_code);
    error = 1;
    return 0;
}

/* Apply the cursor to the Chromium OS X11 server.
 * Adapted from the XcursorImageLoadCursor implementation in libXcursor,
 * copyright 2002 Keith Packard.
 */
static void apply_cursor(Display* d, Window w, XFixesCursorImage *image) {
    static Cursor cur_cursor = 0;
    XImage ximage;
    Pixmap pixmap;
    Picture picture;
    GC gc;
    XRenderPictFormat *format;
    Cursor cursor;

    /* Unset the current cursor if no image is passed. */
    if (!image) {
        if (cur_cursor) {
            XUndefineCursor(d, w);
            XFreeCursor(d, cur_cursor);
            cur_cursor = 0;
        }
        return;
    }

    /* Collapse 64-bit pixels down to 32-bit pixels if needed */
    if (sizeof(image->pixels[0]) == 8) {
        int i;
        int *pixels = (int *) image->pixels;
        for (i = 0; i < image->width * image->height; ++i) {
            pixels[i] = pixels[i*2];
        }
    }

    ximage.width = image->width;
    ximage.height = image->height;
    ximage.xoffset = 0;
    ximage.format = ZPixmap;
    ximage.data = (char *) image->pixels;
    ximage.byte_order = LSBFirst;
    ximage.bitmap_unit = 32;
    ximage.bitmap_bit_order = ximage.byte_order;
    ximage.bitmap_pad = 32;
    ximage.depth = 32;
    ximage.bits_per_pixel = 32;
    ximage.bytes_per_line = image->width * 4;
    ximage.red_mask = 0xff0000;
    ximage.green_mask = 0x00ff00;
    ximage.blue_mask = 0x0000ff;
    ximage.obdata = 0;
    if (!XInitImage(&ximage)) {
        puts("failed to init image");
        return;
    }
    pixmap = XCreatePixmap(d, w, image->width, image->height, 32);
    gc = XCreateGC(d, pixmap, 0, 0);
    XPutImage(d, pixmap, gc, &ximage, 0, 0, 0, 0, image->width, image->height);
    XFreeGC(d, gc);
    format = XRenderFindStandardFormat(d, PictStandardARGB32);
    picture = XRenderCreatePicture(d, pixmap, format, 0, 0);
    XFreePixmap(d, pixmap);
    cursor = XRenderCreateCursor(d, picture, image->xhot, image->yhot);
    XRenderFreePicture(d, picture);
    XDefineCursor(d, w, cursor);
    XFlush(d);
    if (cur_cursor)
        XFreeCursor(d, cur_cursor);
    cur_cursor = cursor;
}

int main(int argc, char** argv) {
    if (argc != 2 || !argv[1][0] || !argv[1][1]) {
        fprintf(stderr, "Usage: %s chrootdisplay\n", argv[0]);
        return 2;
    }
    /* Make sure the displays aren't equal */
    char *cros_n = XDisplayName(NULL);
    if (cros_n[1] == argv[1][1]) {
        fprintf(stderr, "You must specify a different display.\n");
        return 2;
    }
    /* Open the displays */
    Display *cros_d, *chroot_d;
    Window cros_w, chroot_w;
    if (!(cros_d = XOpenDisplay(NULL))) {
        fprintf(stderr, "Failed to open Chromium OS display\n");
        return 1;
    }
    if (!(chroot_d = XOpenDisplay(argv[1]))) {
        fprintf(stderr, "Failed to open chroot display %s\n", argv[1]);
        return 1;
    }
    /* Get the XFixes extension for the chroot to monitor the cursor */
    int xfixes_event, xfixes_error;
    if (!XFixesQueryExtension(chroot_d, &xfixes_event, &xfixes_error)) {
        fprintf(stderr, "chroot is missing XFixes extension\n");
        return 1;

    }
    XSetErrorHandler(error_handler);
    /* Get the root windows */
    cros_w = DefaultRootWindow(cros_d);
    chroot_w = DefaultRootWindow(chroot_d);
    /* Monitor the chroot root window for cursor changes */
    XFixesSelectCursorInput(chroot_d, chroot_w, XFixesDisplayCursorNotifyMask);
    XEvent e;
    while (!error) {
        XNextEvent(chroot_d, &e);
        if (error) break;
        if (e.type != xfixes_event + XFixesCursorNotify) continue;
        /* Grab the new cursor and apply it to the Chromium OS X11 server */
        XFixesCursorImage *img = XFixesGetCursorImage(chroot_d);
        apply_cursor(cros_d, cros_w, img);
        XFree(img);
    }
    /* Clean up */
    apply_cursor(cros_d, cros_w, NULL);
    XCloseDisplay(cros_d);
    XCloseDisplay(chroot_d);
    return 0;
}
