/* Copyright (c) 2015 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */
#include "websocket.h"
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/epoll.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <stddef.h>

#define MAX_EVENTS 100

const char *SOCKET_DIR = "/var/run/crouton-ext";
const char *SOCKET_PATH = "/var/run/crouton-ext/socket";

int send_pid_fd(int conn, long pid, int fd)
{
    struct msghdr msg = {0};
    struct cmsghdr *cmsg;
    struct iovec iov;
    char buf[CMSG_SPACE(sizeof(int))]; /* ancillary data buffer */

    /* It is not necessary to sent the pid. However, to pass fd using sendmsg,
     * at least 1 byte of data must be sent.
     */
    iov.iov_base = &pid;
    iov.iov_len = sizeof(pid);

    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    if (fd > 0) {
        msg.msg_control = buf;
        msg.msg_controllen = sizeof(buf);

        cmsg = CMSG_FIRSTHDR(&msg);
        cmsg->cmsg_level = SOL_SOCKET;
        cmsg->cmsg_type = SCM_RIGHTS;
        cmsg->cmsg_len = CMSG_LEN(sizeof(int));

        *((int *)CMSG_DATA(cmsg)) = fd;
    } else {
        msg.msg_control = NULL;
        msg.msg_controllen = 0;
    }

    return sendmsg(conn, &msg, 0);
}


int find_nacl(int conn)
{
    char argbuf[70], outbuf[256];
    char* cut;
    int idx = 0, c;

    if ((c = read(conn, argbuf, sizeof(argbuf)-1)) < 0) {
       syserror("Failed to read arguments");
       return -1;
    }
    argbuf[c] = 0;

    cut = strchr(argbuf, ' ');
    if (!cut) {
        error("No ' ' in findnacl arguments: %s.", argbuf);
        return -1;
    }
    *cut = 0;

    char *cmd = "croutonfindnacl";
    char* args[] = {cmd, argbuf, cut + 1, NULL};

    c = popen2(cmd, args, NULL, 0, outbuf, sizeof(outbuf)-1);
    if (c <= 0) {
        error("Error running helper");
        return -1;
    }
    outbuf[c] = 0;

    /* Parse PID:file output */
    cut = strchr(outbuf, ':');
    if (!cut) {
        error("No ':' in helper reply: %s.", outbuf);
        return -1;
    }
    *cut = 0;

    char* endptr;
    long pid = strtol(outbuf, &endptr, 10);
    if(outbuf == endptr || *endptr != '\0') {
        error("Invalid pid: %s", outbuf);
        return -1;
    }

    char* file = cut+1;
    int ret = 0;
    int fd = -1;
    if (pid > 0) {
        if ((fd = open(file, O_RDWR)) < 0)
            syserror("Cannot open file %s", file);
    }

    if (send_pid_fd(conn, pid, fd) < 0) {
        syserror("FD-passing failed.");
        ret = -1;
    }

    close(fd);
    return ret;
}

int main()
{
    int sock, conn, n, i, fd;
    int maxfd;
    struct sockaddr_un addr;
    struct epoll_event ev, events[MAX_EVENTS];
    char args[64];
    fd_set readset, recvset;

    /* Set egid to be 27 (video) and change the umask to 007,
     * so that normal user can also access the socket if they
     * are in video group.
     */
    if (setegid(27) < 0) {
        syserror("Cannot set gid to 27");
        return -1;
    }
    umask(S_IROTH | S_IWOTH | S_IXOTH);

    if (mkdir(SOCKET_DIR, 0770) < 0) {
        if (errno != EEXIST) {
            syserror("Cannot create %s", SOCKET_DIR);
            return -1;
        }
    }

    if ((sock = socket(AF_UNIX, SOCK_STREAM, 0)) < 0) {
        syserror("Failed to create socket.");
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path));

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        syserror("Failed to bind address: %s.", SOCKET_PATH);
        return -1;
    }

    if (listen(sock, 1024) < 0) {
        syserror("Failed to listen on %s.", SOCKET_PATH);
        return -1;
    }

    FD_ZERO(&readset);
    FD_SET(sock, &readset);

    maxfd = sock;

    for (;;) {
        memcpy(&recvset, &readset, sizeof(recvset));
        n = select(maxfd + 1, &recvset, NULL, NULL, NULL);

        for (fd = 0; fd <= maxfd; fd++) {
            if (FD_ISSET(fd, &recvset)) {
                if (fd == sock) {
                    conn = accept(sock, NULL, 0);
                    if (conn < 0) {
                        syserror("Connection error.");
                        continue;
                    }
                    if (conn > maxfd)
                        maxfd = conn;
                    FD_SET(conn, &readset);
                }
                else {
                    find_nacl(fd);
                    close(fd);
                    FD_CLR(fd, &readset);
                }
            }
        }
    }

    return 0;
}
