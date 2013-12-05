/* Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Maps and raises the specified window id (integer).
 */

/* TODO: use XResizeWindow to do the +1 width ratpoison hack.
 * And at this point, we might as well use XMoveResizeWindow, rename this to
 * wmtool and unmap the previously-mapped window, and perhaps call the
 * equivalent of XRefresh, eliminating the need for ratpoison entirely (!!).
 */

#include <X11/Xlib.h>
#include <stdlib.h>

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    Display* display = XOpenDisplay(NULL);
    if (!display) return 1;
    XMapRaised(display, atoi(argv[1]));
    XCloseDisplay(display);
    return 0;
}
