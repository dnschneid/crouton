/* Copyright (c) 2015 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Monitors and displays XInput 2 raw events, such as key presses, mouse
 * motion/clicks, etc.
 */

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
    int firstev, firsterr;
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
                         &xi_opcode, &firstev, &firsterr)) {
        fprintf(stderr, "X Input extension not available.\n");
        exit(1);
    }

    /* Listen on root window so that we do not need to create our own. */
    Window win = DefaultRootWindow(display);

    XIEventMask eventmask;

    eventmask.deviceid = XIAllMasterDevices;
    unsigned char mask[XIMaskLen(XI_LASTEVENT)];
    memset(mask, 0, sizeof(mask));
    XISetMask(mask, XI_RawKeyPress);
    XISetMask(mask, XI_RawKeyRelease);
    XISetMask(mask, XI_RawButtonPress);
    XISetMask(mask, XI_RawButtonRelease);
    XISetMask(mask, XI_RawMotion);
    XISetMask(mask, XI_RawTouchBegin);
    XISetMask(mask, XI_RawTouchUpdate);
    XISetMask(mask, XI_RawTouchEnd);
    eventmask.mask = mask;
    eventmask.mask_len = sizeof(mask);

    /* select on the window */
    XISelectEvents(display, win, &eventmask, 1);

    XEvent event;
    XGenericEventCookie *cookie = &event.xcookie;

    while (!terminate) {
        XNextEvent(display, &event);

        if (XGetEventData(display, cookie)) {
            if (cookie->extension == xi_opcode && cookie->type == GenericEvent) {
                switch(cookie->evtype) {
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
    }

    return 0;
}
