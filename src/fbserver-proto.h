/* Copyright (c) 2014 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * WebSocket fbserver shared structures.
 *
 */

#include <stdint.h>

/* WebSocket constants */
#define VERSION "VF1"
#define PORT_BASE 30010

struct  __attribute__((__packed__)) screen {
    char type; /* 'S' */
    uint8_t shm:1; /* Transfer data through shm */
    uint8_t refresh:1; /* Force a refresh, even if no damage is observed */
    uint16_t width;
    uint16_t height;
    uint64_t paddr; /* shm: client buffer address */
    uint64_t sig; /* shm: signature at the beginning of buffer */
};

struct  __attribute__((__packed__)) screen_reply {
    char type; /* 'S' */
    uint8_t shm:1; /* Data was transfered through shm */
    uint8_t shmfailed:1; /* Set to 1 if shm trick has failed */
    uint8_t updated:1; /* Set to 1 if data has been updated */
    uint8_t cursor_updated:1; /* Set to 1 if cursor has been updated */
    uint16_t width;
    uint16_t height;
    uint32_t cursor_serial; /* Unique cursor serial number */
};

/* Ask for cursor image (if serial is unknown) */
struct  __attribute__((__packed__)) cursor {
    char type; /* 'P' */
};

struct  __attribute__((__packed__)) cursor_reply {
    char type; /* 'P' */
    uint16_t width, height;
    uint16_t xhot, yhot;
    uint32_t cursor_serial;
    uint32_t pixels[0];
};

/* Change resolution (query + reply) */
struct  __attribute__((__packed__)) resolution {
    char type; /* 'R' */
    uint16_t width;
    uint16_t height;
};

struct  __attribute__((__packed__)) key {
    char type; /* 'K' */
    uint8_t down:1; /* 1: down, 0: up */
    uint32_t keysym;
};

struct  __attribute__((__packed__)) mousemove {
    char type; /* 'M' */
    uint16_t x;
    uint16_t y;
};

struct  __attribute__((__packed__)) mouseclick {
    char type; /* 'C' */
    uint8_t down:1;
    uint8_t button;
};
