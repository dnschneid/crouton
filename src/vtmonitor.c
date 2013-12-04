/* Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Monitors changes in virtual terminal (VT). This is done by opening
 * /sys/class/tty/tty0/active, and waiting for POLLPRI event. Then, we
 * seek to the beginning of the file, read its content (which looks
 * like ttyX), and start polling again.
 */

#include <poll.h>
#include <string.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#define SYSFILE "/sys/class/tty/tty0/active"

int main(int argc, char **argv) {
    int fd;
    struct pollfd fds[1];
    char buffer[16];

    fd = open(SYSFILE, O_RDONLY);

    if (fd < 0) {
        perror("Cannot open " SYSFILE);
        return 1;
    }

    memset(fds, 0, sizeof(fds));
    fds[0].fd = fd;
    fds[0].events = POLLPRI;

    while (1) {
        /* Wait for events */
        int n = poll(fds, 1, -1);
        if (n <= 0) {
            perror("poll error.");
            return 1;
        }

        if (fds[0].revents & POLLPRI) {
            /* Seek back to beginning of file and read the tty number. */
            lseek(fd, 0, SEEK_SET);
            n = read(fd, buffer, 16);
            if (n <= 0) {
                perror("Cannot read from " SYSFILE " file.");
                return 1;
            }

            /* Write tty number to stdout */
            fwrite(buffer, n, 1, stdout);
            fflush(stdout);
        } else {
            fprintf(stderr, "Unknown poll event.\n");
            return 1;
        }
    }

    return 0;
}
