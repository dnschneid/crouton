/* Copyright (c) 2015 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */

static const char* USAGE =
"Performs WM-related tasks on top-level windows.\n"
"Designed to work without a real WM in place.\n"
"\n"
"Usage:\n"
"%s l[ist] [1][i][m][n]\n"
"    Lists the IDs of all top-level windows.\n"
"    1  only list the topmost window\n"
"    i  list the window IDs as integers\n"
"    m  mark the window ID of the topmost window with a *\n"
"    n  output the name of the windows before the IDs\n"
"%s r[aise] window_id\n"
"    Raises the specified window, keeping the relative order of the windows.\n"
;

#include <X11/Xlib.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

int listMapped(Display *display, const char *arg) {
    int one = strchr(arg, '1') != NULL;
    int asints = strchr(arg, 'i') != NULL;
    int names = strchr(arg, 'n') != NULL;
    int mark = strchr(arg, 'm') != NULL;

    Window parent, root, *children;
    unsigned int nchildren;
    XWindowAttributes attributes;
    char *name;

    if (!XQueryTree(display, DefaultRootWindow(display), &root, &parent,
                   &children, &nchildren))
        return 1;
    if (!children)
        return 0;

    while (nchildren--) {
        if (XGetWindowAttributes(display, children[nchildren],
                    &attributes) && attributes.map_state == IsViewable) {
            if (names) {
                if (XFetchName(display, children[nchildren], &name) && name) {
                    printf("%s ", name);
                    XFree(name);
                } else {
                    printf("Unknown ");
                }
            }
            printf(asints ? "%u" : "0x%x", (unsigned int)children[nchildren]);
            printf(mark ? "*\n" : "\n");
            mark = 0;
            if (one) {
                break;
            }
        }
    }

    XFree(children);
    return 0;
}

int raiseWindow(Display *display, Window window) {
    Window parent, root, *children, *neworder;
    unsigned int nchildren, i, rotate;
    XWindowAttributes attr;

    if (!XQueryTree(display, DefaultRootWindow(display), &root, &parent,
                   &children, &nchildren))
        return 1;
    if (!children)
        return 2;

    for (rotate = 0; rotate < nchildren; ++rotate) {
        if (children[nchildren-1 - rotate] == window)
            break;
    }
    if (rotate == nchildren) {
        XFree(children);
        return 2;
    }

    if (rotate > 0) {
        /* Unmap and remap the old top-level window to kill off any mouse and
         * keyboard hooks */
        XUnmapWindow(display, children[nchildren-1]);

        neworder = (Window*)malloc(nchildren * sizeof(*neworder));
        /* XQueryTree returns children in back-to-front order, while
         * XRestackWindows takes a front-to-back list. Reverse the order and
         * rotate the position of the children -n positions to put the requested
         * window into the first position in the list.
         */
        for (i = 0; i < nchildren; ++i) {
            neworder[nchildren-1 - ((i+rotate) % nchildren)] = children[i];
        }
        XRestackWindows(display, neworder, nchildren);
        free(neworder);

        /* Split the map from the unmap to reduce the number of events */
        XMapWindow(display, children[nchildren-1]);
    }
    XFree(children);

    if (!XGetWindowAttributes(display, DefaultRootWindow(display), &attr)) {
        return 1;
    }
    /* Twiddle the width of the window to force a full refresh */
    XMoveResizeWindow(display, window,
                      attr.x, attr.y, attr.width-1, attr.height);
    XMoveResizeWindow(display, window,
                      attr.x, attr.y, attr.width,   attr.height);

    return 0;
}

void usage(char** argv) {
    fprintf(stderr, USAGE, argv[0], argv[0]);
}

int main(int argc, char** argv) {
    int ret = 2;
    if (argc < 2 || argc > 3) {
        usage(argv);
        return 2;
    }
    Display *display = XOpenDisplay(NULL);
    if (!display) {
        fputs("Unable to open display\n", stderr);
        return 1;
    }
    switch (argv[1][0]) {
        case 'l':
            if (argc > 3) {
                usage(argv);
                break;
            }
            ret = listMapped(display, argc >= 3 ? argv[2] : "");
            break;
        case 'r':
            if (argc != 3) {
                usage(argv);
                break;
            }
            ret = raiseWindow(display, (Window)strtol(argv[2], NULL, 0));
            break;
        default:
            usage(argv);
            break;
    }
    XCloseDisplay(display);
    return ret;
}
