/* Copyright (c) 2015 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * WebSocket fbserver shared structures.
 *
 */

#ifndef FB_SERVER_PROTO_H_
#define FB_SERVER_PROTO_H_

#include <stdint.h>

/* WebSocket constants */
#define VERSION "VF3"
#define PORT_BASE 30010

/* Request for a frame */
struct  __attribute__((__packed__)) screen {
    char type;  /* 'S' */
    uint8_t shm:1;  /* Transfer data through shm */
    uint8_t refresh:1;  /* Force a refresh, even if no damage is observed */
    uint16_t width;
    uint16_t height;
    uint64_t paddr;  /* shm: client buffer address */
    uint64_t sig;  /* shm: signature at the beginning of buffer */
};

/* Reply to request for a frame */
struct  __attribute__((__packed__)) screen_reply {
    char type;  /* 'S' */
    uint8_t shm:1;  /* Data was transfered through shm */
    uint8_t shmfailed:1;  /* shm trick has failed */
    uint8_t updated:1;  /* data has been updated (Xdamage) */
    uint8_t cursor_updated:1;  /* cursor has been updated */
    uint16_t width;
    uint16_t height;
    uint32_t cursor_serial;  /* Cursor to display */
};

/* Request for cursor image (if cursor_serial is unknown) */
struct  __attribute__((__packed__)) cursor {
    char type;  /* 'P' */
};

/* Reply to requets for a cursor image (variable length) */
struct  __attribute__((__packed__)) cursor_reply {
    char type;  /* 'P' */
    uint16_t width, height;
    uint16_t xhot, yhot;  /* "Hot" coordinates */
    uint32_t cursor_serial;  /* X11 unique serial number */
    uint32_t pixels[0];  /* Payload, 32-bit per pixel */
};

/* Change resolution (query + reply) */
struct  __attribute__((__packed__)) resolution {
    char type;  /* 'R' */
    uint16_t width;
    uint16_t height;
};

/* Press a key */
struct  __attribute__((__packed__)) key {
    char type;  /* 'K' */
    uint8_t down:1;  /* 1: down, 0: up */
    uint8_t keycode;  /* X11 KeyCode (8-255) */
};

/* Press a key (compatibility with VF1) */
/* TODO: Remove support for VF1. */
struct  __attribute__((__packed__)) key_vf1 {
    char type;  /* 'K' */
    uint8_t down:1;  /* 1: down, 0: up */
    uint32_t keysym;  /* X11 KeySym */
};

/* Move the mouse */
struct  __attribute__((__packed__)) mousemove {
    char type;  /* 'M' */
    uint16_t x;
    uint16_t y;
};

/* Send initialization info */
struct  __attribute__((__packed__)) initinfo {
    char type; /* I */
    uint8_t freon; /* 0: not using freon, 1: using freon */
};

/* Click the mouse */
struct  __attribute__((__packed__)) mouseclick {
    char type;  /* 'C' */
    uint8_t down:1;
    uint8_t button;  /* X11 button number (e.g. 1 is left) */
};

#endif  /* FB_SERVER_PROTO_H_ */
