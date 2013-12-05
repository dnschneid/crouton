/* Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Maps and raises the specified window id (integer).
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
