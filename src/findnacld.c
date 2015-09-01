#include "websocket.h"
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/epoll.h>
#include <fcntl.h>
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

    iov.iov_base = &pid;
    iov.iov_len = sizeof(pid);

    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    if (fd > 0) {
        msg.msg_control = buf;
        msg.msg_controllen = CMSG_SPACE(sizeof(int));

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
    int idx = 0, c, len;

    if ((len = read(conn, argbuf, 64)) < 0) {
       syserror("Failed to read arguments");
       return -1;
    }
    argbuf[len] = 0;

    cut = strchr(argbuf, ' ');
    if (!cut) {
        error("No ' ' in findnacl arguments: %s.", argbuf);
        return -1;
    }
    *cut = 0;

    char *cmd = "croutonfindnacl";
    char* args[] = {cmd, argbuf, cut + 1, NULL};

    c = popen2(cmd, args, NULL, 0, outbuf, sizeof(outbuf));
    if (c <= 0) {
        error("Error running helper");
        return -1;
    }
    outbuf[c < sizeof(outbuf) ? c : (sizeof(outbuf)-1)] = 0;

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
    if (pid > 0 && (fd = open(file, O_RDWR)) < 0) {
        syserror("Cannot open file %s", file);
    }

    if (send_pid_fd(conn, pid, fd) < 0) {
        syserror("FD-passing failed.");
        ret = 1;
    }

    close(fd);
    return ret;
}

int main()
{
    int sock, conn, n, i;
    int epollfd;
    struct sockaddr_un addr;
    struct epoll_event ev, events[MAX_EVENTS];
    char args[64];

    if (setegid(1000)) {
        syserror("Cannot set gid to 1000");
        return -1;
    }
    if (mkdir(SOCKET_DIR)) {
        if (errno != EEXIST) {
            syserror("Cannot create %s", SOCKET_DIR);
            return -1;
        }
    }
    if (chmod(SOCKET_DIR, 0770)) {
        syserror("Failed to change permission of %s.", SOCKET_DIR);
        return -1;
    }

    if ((sock = socket(AF_UNIX, SOCK_STREAM, 0)) < 0) {
        syserror("Failed to create socket.");
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, SOCKET_PATH);

    if (bind(sock, (struct sockaddr *)&addr, offsetof(struct sockaddr_un, sun_path) + strlen(SOCKET_PATH) + 1)) {
        syserror("Failed to bind address: %s.", SOCKET_PATH);
        return -1;
    }
    if (chmod(SOCKET_PATH, 0770) < 0) {
        syserror("Failed to change permission of %s.", SOCKET_PATH);
        return -1;
    }

    if (listen(sock, 1024) < 0) {
        syserror("Failed to listen on %s.", SOCKET_PATH);
        return -1;
    }


    if ((epollfd = epoll_create1(0)) < 0) {
        syserror("Failed to create epoll instance.");
        return -1;
    }

    ev.events = POLLIN;
    ev.data.fd = sock;
    if (epoll_ctl(epollfd, EPOLL_CTL_ADD, sock, &ev) < 0) {
        syserror("Failed to add new poll event.");
        return -1;
    }

    for (;;) {
        n = epoll_wait(epollfd, events, MAX_EVENTS, -1);

        for (i = 0; i < n; i++) {
            if (events[i].data.fd == sock) {
                conn = accept(sock, NULL, 0);
                if (conn < 0) {
                    syserror("Connection error.");
                }
                ev.events = EPOLLIN;
                ev.data.fd = conn;
                if (epoll_ctl(epollfd, EPOLL_CTL_ADD, conn, &ev) < 0) {
                    syserror("Failed to add new poll event.");
                }
            }
            else {
                find_nacl(events[i].data.fd);
                close(events[i].data.fd);
            }
        }
    }

    return 0;
}
