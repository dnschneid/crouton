/* Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Monitors the specified X11 server for cursor change events, and copies the
 * cursor image over to the X11 server specified in DISPLAY.
 *
 * This is an heavily simplified version of xinput/test-xi2.c:
 *
 * Copyright © 2009 Red Hat, Inc.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

/* gcc xi2event.c -o croutonxi2event -lXi -lX11 */

#include <X11/Xlib.h>
#include <X11/extensions/XInput.h>
#include <X11/extensions/XInput2.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Print a XIRawEvent, including the list of valuators, all on one line. */
static void print_rawevent(XIRawEvent *event) {
    int i;
    int lasti = -1;
    double *val;

    printf("EVENT type %d ", event->evtype);
    printf("device %d %d ", event->deviceid, event->sourceid);
    printf("detail %d ", event->detail);
    printf("valuators");

    /* Get the index of the last valuator that is set */
    for (i = 0; i < event->valuators.mask_len * 8; i++) {
        if (XIMaskIsSet(event->valuators.mask, i)) {
            lasti = i;
        }
    }

    /* Print each valuator's value, nan if the valuator is not set. */
    val = event->valuators.values;
    for (i = 0; i <= lasti; i++) {
        if (XIMaskIsSet(event->valuators.mask, i)) {
            printf(" %.2f", *val++);
        } else {
            printf(" nan");
        }
    }
    printf("\n");
}

void usage(char* argv0) {
    fprintf(stderr, "%s [-1]\n", argv0);
    fprintf(stderr, "   Monitors and displays XInput 2 raw events.\n");
    fprintf(stderr, "   -1: only wait for one event, then exit.\n");
    exit(1);
}

int main(int argc, char *argv[]) {
    XIEventMask mask;
    Window win;
    int event, error;
    int xi_opcode = -1;
    int one_event = 0;
    int terminate = 0;

    /* stdout: line buffering */
    setvbuf(stdout, NULL, _IOLBF, 0);

    /* Parse arguments */
    if (argc == 2) {
        printf("%s", argv[1]);
        if (strcmp(argv[1], "-1") == 0)
            one_event = 1;
        else
            usage(argv[0]);
    } else if (argc > 2) {
        usage(argv[0]);
    }

    Display* display = XOpenDisplay(NULL);

    if (display == NULL) {
        fprintf(stderr, "Unable to connect to X server\n");
        exit(1);
    }

    if (!XQueryExtension(display, "XInputExtension",
                         &xi_opcode, &event, &error)) {
        fprintf(stderr, "X Input extension not available.\n");
        exit(1);
    }

    /* Listen on root window so that we do not need to create our own. */
    win = DefaultRootWindow(display);

    /* Register all raw input events. */
    mask.deviceid = XIAllMasterDevices;
    mask.mask_len = XIMaskLen(XI_LASTEVENT);
    mask.mask = calloc(mask.mask_len, sizeof(char));
    XISetMask(mask.mask, XI_RawKeyPress);
    XISetMask(mask.mask, XI_RawKeyRelease);
    XISetMask(mask.mask, XI_RawButtonPress);
    XISetMask(mask.mask, XI_RawButtonRelease);
    XISetMask(mask.mask, XI_RawMotion);
    XISetMask(mask.mask, XI_RawTouchBegin);
    XISetMask(mask.mask, XI_RawTouchUpdate);
    XISetMask(mask.mask, XI_RawTouchEnd);

    XISelectEvents(display, win, &mask, 1);
    XSync(display, False);

    free(mask.mask);

    while(!terminate) {
        XEvent ev;
        XGenericEventCookie *cookie = (XGenericEventCookie*)&ev.xcookie;
        XNextEvent(display, (XEvent*)&ev);

        if (XGetEventData(display, cookie) &&
            cookie->type == GenericEvent &&
            cookie->extension == xi_opcode) {
            switch (cookie->evtype) {
                case XI_RawKeyPress:
                case XI_RawKeyRelease:
                case XI_RawButtonPress:
                case XI_RawButtonRelease:
                case XI_RawMotion:
                case XI_RawTouchBegin:
                case XI_RawTouchUpdate:
                case XI_RawTouchEnd:
                    print_rawevent(cookie->data);
                    if (one_event)
                        terminate = 1;
                    break;
                default:
                    break;
            }
        }

        XFreeEventData(display, cookie);
    }

    XDestroyWindow(display, win);

    return EXIT_SUCCESS;
}
