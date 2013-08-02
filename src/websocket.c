/* Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * WebSocket server to interface with crouton Chromium extension, that provides
 * clipboard synchronization (and possibly other features in the future).
 *
 * Things that are supported, but not tested:
 *  - Fragmented packets from client
 *  - Ping packets
 */

#define _GNU_SOURCE /* for ppoll */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <poll.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <signal.h>

const int BUFFERSIZE = 4096;

/* Websocket constants */
#define VERSION "1"
const int PORT = 30001;
const int FRAMEMAXHEADERSIZE = 2+8;
const int MAXFRAMESIZE = 16*1048576; // 16MiB
const char* GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/* Pipe constants */
const char* PIPE_DIR = "/tmp/crouton-ext";
const char* PIPEIN_FILENAME = "/tmp/crouton-ext/in";
const char* PIPEOUT_FILENAME = "/tmp/crouton-ext/out";
const int PIPEOUT_WRITE_TIMEOUT = 3000;

/* 0 - Quiet
 * 1 - General messages (init, new connections)
 * 2 - 1 + Messages on each new transfers
 * 3 - 2 + Extra information */
static int verbose = 0;

static int server_fd = -1;
static int pipein_fd = -1;
static int client_fd = -1;
static int pipeout_fd = -1;

/* Prototypes */
static int socket_client_write_frame(char* buffer, unsigned int size,
                                     unsigned int opcode, int fin);
static int socket_client_read_frame_header(int* fin, uint32_t* maskkey, int* length);
static int socket_client_read_frame_data(char* buffer, unsigned int size,
                                         uint32_t maskkey);
static void socket_client_close(int close_reason);

static void pipeout_close();

/**/
/* Helper functions */
/**/

/* Read exactly size bytes from fd, no matter how many reads it takes */
static int block_read(int fd, char* buffer, size_t size) {
    int n;
    int tot = 0;

    while (tot < size) {
        n = read(fd, buffer+tot, size-tot);
        if (verbose >= 3)
            printf("block_read n=%d+%d/%zd\n", n, tot, size);
        if (n < 0) return n;
        if (n == 0) return -1; /* EOF */
        tot += n;
    }

    return tot;
}

/* Write exactly size bytes from fd, no matter how many writes it takes */
static int block_write(int fd, char* buffer, size_t size) {
    int n;
    int tot = 0;

    while (tot < size) {
        n = write(fd, buffer+tot, size-tot);
        if (verbose >= 3)
            printf("block_write n=%d+%d/%zd\n", n, tot, size);
        if (n < 0) return n;
        if (n == 0) return -1;
        tot += n;
    }

    return tot;
}

/* Run external command, piping some data on its stdin, and reading back
 * the output. */
static int popen2(char* cmd, char* input, int inlen, char* output, int outlen) {
    pid_t pid = 0;
    int stdin_fd[2];
    int stdout_fd[2];

    if (pipe(stdin_fd) < 0 || pipe(stdout_fd) < 0) {
        perror("popen2: Failed to create pipe.");
        return -1;
    }

    pid = fork();

    if (pid < 0) {
        perror("popen2: Fork error.");
        return -1;
    } else if (pid == 0) {
        /* Child: connect stdin/out to the pipes, close the unneeded halves */
        close(stdin_fd[1]);
        dup2(stdin_fd[0], STDIN_FILENO);
        close(stdout_fd[0]);
        dup2(stdout_fd[1], STDOUT_FILENO);

        execlp(cmd, cmd, NULL);

        fprintf(stderr, "popen2: Error running %s\n", cmd);
        exit(1);
    }

    /* Parent */
    if (write(stdin_fd[1], input, inlen) != inlen) {
        perror("popen2: Cannot write to pipe!\n");
    }
    close(stdin_fd[1]);

    outlen = read(stdout_fd[0], output, outlen);
    close(stdout_fd[0]);

    /* Wait for process to finish to avoid leaving a zombie */
    waitpid(pid, NULL, 0);

    return outlen;
}

/* Open a pipe in non-blocking mode, then set it back to blocking mode. */
static int pipe_open_block(const char* path, int oflag) {
    int fd;

    if (verbose >= 3)
        printf("pipe_open_block: %s\n", path);

    fd = open(path, oflag | O_NONBLOCK);
    if (fd < 0)
        return -1;

    /* Remove non-blocking flag */
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) < 0) {
        perror("pipe_open_block: error in fnctl GETFL/SETFL.");
        return -2;
    }

    return fd;
}

/**/
/* Pipe out functions */
/**/

/* Open the pipe out. */
static int pipeout_open() {
    int i;

    if (verbose >= 2)
        printf("pipeout_open: opening pipe out\n");

    /* Unfortunately, while opening pipes for writing in blocking mode, "open"
     * blocks. In non-blocking mode, it fails (returns -1), which means that we
     * cannot open the pipe, then use functions like poll/select like we are
     * doing for pipein. Therefore, we are forced to poll manually.
     * Using usleep is simpler, and probably better than measuring time elapsed:
     * If the system hangs for a while (like during large I/O writes), this will
     * still wait around PIPEOUT_WRITE_TIMEOUT ms of actual user time, instead
     * of clock time. */
    for (i = 0; i < PIPEOUT_WRITE_TIMEOUT/10; i++) {
        pipeout_fd = pipe_open_block(PIPEOUT_FILENAME, O_WRONLY);
        if (pipeout_fd > -1)
            break;
        if (pipeout_fd == -2)
            return -1;
        usleep(10000);
    }

    if (pipeout_fd < 0) {
        fprintf(stderr, "pipeout_open: timeout while opening.\n");
        return -1;
    }

    return 0;
}

static void pipeout_close() {
    if (verbose >= 2)
        printf("pipeout_close\n");

    if (pipeout_fd < 0)
        return;

    close(pipeout_fd);
    pipeout_fd = -1;
}

static int pipeout_write(char* buffer, int len) {
    int n;

    if (verbose >= 3)
        printf("pipeout_write (fd=%d, len=%d)\n", pipeout_fd, len);

    if (pipeout_fd < 0)
        return -1;

    n = block_write(pipeout_fd, buffer, len);
    if (n < 0) {
        fprintf(stderr, "pipeout_write: Error writing to pipe.\n");
        pipeout_close();
    }
    return n;
}

/* Open pipe out, write a string, and close the pipe. */
static void pipeout_error(char* str) {
    pipeout_open();
    pipeout_write(str, strlen(str));
    pipeout_close();
}

/**/
/* Pipe in functions */
/**/

/* Flush the pipe (in case of error), close it, then reopen it. This is
 * necessary to prevent poll from getting continuous POLLHUP when the process
 * that wrote into the pipe terminates (croutonurlhandler for example).
 * This MUST be called before anything is written to pipeout to avoid race
 * condition. */
static void pipein_reopen() {
    if (pipein_fd > -1) {
        char buffer[BUFFERSIZE];
        while (read(pipein_fd, buffer, BUFFERSIZE) > 0);
        close(pipein_fd);
    }

    pipein_fd = pipe_open_block(PIPEIN_FILENAME, O_RDONLY);
    if (pipein_fd < 0) {
        perror("pipein_reopen: cannot open pipe in.\n");
        exit(1);
    }
}

/* Read data from the pipe */
static void pipein_read() {
    int n;
    char buffer[FRAMEMAXHEADERSIZE+BUFFERSIZE];
    int first = 1;

    if (client_fd < 0) {
        printf("pipein_read: no client FD.\n");
        pipein_reopen();
        pipeout_error("EError: not connected\n");
        return;
    }

    while (1) {
        n = read(pipein_fd, buffer+FRAMEMAXHEADERSIZE, BUFFERSIZE);
        if (verbose >= 3)
            printf("pipein_read n=%d\n", n);

        if (n < 0) {
            perror("pipein_read: Error reading from pipe.\n");

            exit(1); /* We're dead if that happens... */
        } else if (n == 0) {
            break;
        }

        /* Text or cont frame */
        n = socket_client_write_frame(buffer, n, first ? 1 : 0, 0);
        if (n < 0) {
            printf("pipein_read: error writing frame.\n");
            pipein_reopen();
            pipeout_error("EError: socket write error\n");
            return;
        }

        first = 0;
    }

    if (verbose >= 3)
        printf("pipein_read: EOF\n");

    pipein_reopen();

    /* Empty FIN frame */
    n = socket_client_write_frame(buffer, 0, 0, 1);
    if (n < 0) {
        printf("pipein_read: error writing frame.\n");
        pipeout_error("EError: socket write error\n");
        return;
    }

    if (verbose >= 2)
        printf("pipein_read: Reading answer from client...\n");

    int fin = 0;
    uint32_t maskkey;
    int retry = 0;

    /* Ignore return value, so we still read the frame even if pipeout
     * cannot be open. */
    pipeout_open();

    /* Read possibly fragmented message from WebSocket. */
    while (fin != 1) {
        int len = socket_client_read_frame_header(&fin, &maskkey, &retry);

        if (verbose >= 3)
            printf("pipein_read: len=%d fin=%d retry=%d...\n", len, fin, retry);

        if (retry)
            continue;

        if (len < 0)
            break;

        /* Read the whole frame */
        while (len > 0) {
            int rlen = (len > BUFFERSIZE) ? BUFFERSIZE: len;
            if (socket_client_read_frame_data(buffer, rlen, maskkey) < 0) {
                pipeout_close();
                return;
            }
            /* Ignore return value as well */
            pipeout_write(buffer, rlen);
            len -= rlen;
        }
    }

    pipeout_close();
}

/* Check if filename is a valid FIFO pipe. If not create it. */
int checkfifo(const char* filename) {
    struct stat fstat;

    /* Check if file exists: if not, create it. */
    if (access(filename, F_OK) < 0) {
        /* FIFO does not exist: create it */
        if (mkfifo(filename,
                S_IRUSR|S_IWUSR|S_IRGRP|S_IWGRP|S_IROTH|S_IWOTH) < 0) {
            perror("checkfifo: Cannot create FIFO pipe.");
            return -1;
        }
        return 0;
    }

    /* We must be able to read and write the file. (only one direction is
     * necessary in croutonwebsocket, but croutonclip needs the other direction)
     */
    if (access(filename, R_OK|W_OK) < 0) {
        fprintf(stderr,
                "checkfifo: %s exists, but not readable and writable.\n",
                filename);
        return -1;
    }

    if (stat(filename, &fstat) < 0) {
        perror("checkfifo: Cannot stat FIFO pipe.");
        return -1;
    }

    if (!S_ISFIFO(fstat.st_mode)) {
        fprintf(stderr,
                "checkfifo: %s exists, but is not a FIFO pipe.\n", filename);
        return -1;
    }

    return 0;
}

/* Initialise FIFO pipes. */
void pipe_init() {
    struct stat fstat;

    /* Check if directory exists: if not, create it. */
    if (access(PIPE_DIR, F_OK) < 0) {
        if (mkdir(PIPE_DIR, S_IRWXU|S_IRWXG|S_IRWXO) < 0) {
            perror("checkfifo: Cannot create FIFO pipe directory.");
            return;
        }
    } else {
        if (stat(PIPE_DIR, &fstat) < 0) {
            perror("pipe_init: Cannot stat FIFO pipe directory.");
            return;
        }

        if (!S_ISDIR(fstat.st_mode)) {
            fprintf(stderr,
                   "pipe_init: %s exists, but is not a directory.\n", PIPE_DIR);
            return;
        }
    }

    if (checkfifo(PIPEIN_FILENAME) < 0 ||
        checkfifo(PIPEOUT_FILENAME) < 0) {
        /* checkfifo prints an error already. */
        exit(1);
    }

    pipein_fd = -1;
    pipein_reopen();
}

/**/
/* Websocket functions. */
/**/

/* Close the client socket, possibly sending a close packet. */
static void socket_client_close(int close_reason) {
    if (client_fd < 0)
        return;

    if (close_reason > -1) {
        char buffer[FRAMEMAXHEADERSIZE+32];
        /* RFC does not make it clear if close reason must be an integer
         * or a string. */
        buffer[FRAMEMAXHEADERSIZE] = close_reason >> 8;
        buffer[FRAMEMAXHEADERSIZE+1] = close_reason;
        int length = 2+snprintf(buffer+FRAMEMAXHEADERSIZE+2, 32-2,
                                "croutonwebsocket error.");
        socket_client_write_frame(buffer, length, 8, 1);
        /* FIXME: We are supposed to read back the answer */
    }

    close(client_fd);
    client_fd = -1;
}

/* buffer needs to be FRAMEMAXHEADERSIZE+size long,
 * and data must start at buffer[FRAMEMAXHEADERSIZE] only.
 *  - opcode should generally be 0 (continuation) or 1 (text).
 *  - fin indicates if the this is the last frame in the message
 */
static int socket_client_write_frame(char* buffer, unsigned int size,
                                     unsigned int opcode, int fin) {
    char* pbuffer = buffer+FRAMEMAXHEADERSIZE-2;
    int payloadlen = size;
    int extlensize = 0;
    int i;

    /* Test if we need an extended length field. */
    if (payloadlen > 125) {
        if (payloadlen < 65536) {
            payloadlen = 126;
            extlensize = 2;
        } else {
            payloadlen = 127;
            extlensize = 8;
        }
        pbuffer -= extlensize;

        /* Network-order (big-endian) */
        unsigned int tmpsize = size;
        for (i = extlensize-1; i >= 0; i--) {
            pbuffer[2+i] = tmpsize & 0xff;
            tmpsize >>= 8;
        }
    }

    pbuffer[0] = 0x00;
    if (fin) pbuffer[0] |= 0x80;
    pbuffer[0] |= (opcode & 0x0f);
    pbuffer[1] = payloadlen; /* No mask (0x80) in server->client direction */

    if (block_write(client_fd, pbuffer, 2+extlensize+size) < 0) {
        perror("socket_client_write_frame: write error");
        socket_client_close(-1);
        return -1;
    }

    return size;
}

/* Read a websocket frame header:
 *  - fin indicates in this is the final frame in a fragemented message
 *  - maskkey is the XOR key used for the message
 *  - retry is set to 1 if we receive a control packet, and the caller
 *    should call again
 *  - returns the frame length.
 *
 * Data is then read with socket_client_read_data()
 */
static int socket_client_read_frame_header(int* fin, uint32_t* maskkey, int* retry) {
    char header[2]; /* Min header length */
    char extlen[8]; /* Extended length */
    int n, i;
    int opcode = -1;

    *retry = 0;

    n = block_read(client_fd, header, 2);
    if (n < 0) {
        fprintf(stderr, "socket_client_read_frame_header: Read error.\n");
        socket_client_close(-1);
        return -1;
    }

    int mask;
    uint64_t length;
    *fin = !!(header[0] & 0x80);
    if (header[0] & 0x70) { /* Reserved bits are on */
        fprintf(stderr,
                "socket_client_read_frame_header: Reserved bits are on.\n");
        socket_client_close(1002); /* 1002: Protocol error */
        return -1;
    }
    opcode = header[0] & 0x0F;
    mask = !!(header[1] & 0x80);
    length = header[1] & 0x7F;

    if (verbose >= 2)
        printf("socket_client_read_frame_header: "
               "fin=%d; opcode=%d; mask=%d; length=%llu\n",
               *fin, opcode, mask, (long long unsigned int)length);

    /* Read extended length if necessary */
    int extlensize = 0;
    if (length == 126) extlensize = 2;
    else if (length == 127) extlensize = 8;

    if (extlensize > 0) {
        n = block_read(client_fd, extlen, extlensize);
        if (n < 0) {
            fprintf(stderr, "socket_client_read_frame_header: Read error.\n");
            socket_client_close(-1);
            return -1;
        }

        /* Network-order (big-endian) */
        length = 0;
        for (i = 0; i < extlensize; i++) {
            length = length << 8 | extlen[i];
        }

        if (verbose >= 3)
            printf("socket_client_read_frame_header: extended length=%llu\n",
                   (long long unsigned int)length);
    }

    /* Read masking key if necessary */
    if (mask) {
        n = block_read(client_fd, (char*)maskkey, 4);
        if (n < 0) {
            fprintf(stderr, "socket_client_read_frame_header: Read error.\n");
            socket_client_close(-1);
            return -1;
        }
    } else {
        *maskkey = 0;
        fprintf(stderr, "socket_client_read_frame_header: No mask set.\n");
        socket_client_close(1002);
        return -1;
    }

    if (verbose >= 3)
        printf("socket_client_read_frame_header: maskkey=%04x\n", *maskkey);

    if (length > MAXFRAMESIZE) {
        fprintf(stderr,
                "socket_client_read_frame_header: Frame too big! (%llu>%d)\n",
                (long long unsigned int)length, MAXFRAMESIZE);
        socket_client_close(1009); /* 1009: Message too big */
        return -1;
    }

    /* is opcode continuation, text, or binary? */
    if (opcode != 0 && opcode != 1 && opcode != 2) {
        if (verbose >= 2)
            printf("socket_client_read_frame_header: "
                   "Got a control packet (opcode=%d).\n", opcode);

        /* Control packets cannot be fragmented.
         * Unknown data (opcode 3-7) will result in error anyway. */
        if (*fin == 0) {
            fprintf(stderr, "socket_client_read_frame_header: "
                    "Fragmented unknown packet\n");
            socket_client_close(1002); /* 1002: Protocol error */
            return -1;
        }

        /* Read the rest of the packet */
        char* buffer = malloc(length+3); /* +3 for unmasking safety */
        if (socket_client_read_frame_data(buffer, length, *maskkey) < 0) {
            socket_client_close(-1);
            free(buffer);
            return -1;
        }

        if (opcode == 8) { /* Connection close. */
            fprintf(stderr, "socket_client_read_frame_header: "
                    "Connection close from websocket client.\n");
            socket_client_close(-1);
            free(buffer);
            return -1;
        } else if (opcode == 9) { /* Ping */
            socket_client_write_frame(buffer, length, 10, 1);
        } else if (opcode == 10) { /* Pong */
            /* Do nothing */
        } else { /* Unknown opcode */
            fprintf(stderr, "socket_client_read_frame_header: "
                    "Unknown packet\n");
            socket_client_close(1002); /* 1002: Protocol error */
            free(buffer);
            return -1;
        }

        free(buffer);

        /* Tell the caller to wait for the next packet */
        *retry = 1;
        *fin = 0;
        return 0;
    }

    return length;
}

/* Read frame data from the socket client:
 * - Either reads full buffer size, or fails
 * - Make sure that buffer is at least 4*ceil(size/4) long
 *   (unmasking works with blocks of 4 bytes)
 */
static int socket_client_read_frame_data(char* buffer, unsigned int size,
                                         uint32_t maskkey) {
    int n = block_read(client_fd, buffer, size);
    if (n < 0) {
        fprintf(stderr, "socket_client_read_frame_data: Read error.\n");
        socket_client_close(-1);
        return -1;
    }

    if (maskkey != 0) {
        int i;
        int len32 = (size+3)/4;
        uint32_t* buffer32 = (uint32_t*)buffer;
        for (i = 0; i < len32; i++) {
            buffer32[i] ^= maskkey;
        }
    }

    return n;
}

/* Unrequested data came in from client. */
static void socket_client_read() {
    char* buffer = NULL;
    int length = 0;
    int fin = 0;
    uint32_t maskkey;
    int retry = 0;
    int data = 0; /* 1 if we received some valid data */

    /* Read possible fragmented message into buffer */
    while (fin != 1) {
        int curlen = socket_client_read_frame_header(&fin, &maskkey, &retry);

        if (retry) {
            if (!data) {
                /* We only got a control frame, go back to main loop. We will get
                 * called again if there is more data waiting. */
                return;
            } else {
                continue;
            }
        }

        if (curlen < 0) {
            free(buffer);
            socket_client_close(-1);
            return;
        }

        if (length+curlen > MAXFRAMESIZE) {
            fprintf(stderr, "socket_client_read: "
                    "Message too big (%d>%d)\n", length+curlen, MAXFRAMESIZE);
            free(buffer);
            socket_client_close(1009); /* Message too big */
            return;
        }

        buffer = realloc(buffer, length+curlen+3); /* +3 for unmasking safety */

        if (socket_client_read_frame_data(buffer+length, curlen, maskkey) < 0) {
            fprintf(stderr, "socket_client_read: Read error.\n");
            socket_client_close(-1);
            free(buffer);
            return;
        }

        length += curlen;
    }

    fprintf(stderr, "Received an unexpected packet from client\n");
    socket_client_close(-1);
    free(buffer);
}

/* Send a version packet to the extension, and read VOK reply. */
static void socket_client_sendversion() {
    char* version = "V"VERSION;
    int versionlen = strlen(version);
    char* outbuf = malloc(FRAMEMAXHEADERSIZE+versionlen);
    memcpy(outbuf+FRAMEMAXHEADERSIZE, version, versionlen);

    if (socket_client_write_frame(outbuf, versionlen, 1, 1) < 0) {
        fprintf(stderr, "socket_client_sendversion: Write error.\n");
        socket_client_close(-1);
        free(outbuf);
        return;
    }
    free(outbuf);

    /* Read back response */
    char buffer[32];
    int buflen = 0;
    int fin = 0;
    uint32_t maskkey;
    int retry = 0;

    /* Read possibly fragmented message from WebSocket. */
    while (fin != 1) {
        int len = socket_client_read_frame_header(&fin, &maskkey, &retry);

        if (retry)
            continue;

        if (len < 0) {
            break;
        }

        /* Read the whole frame */
        while (len > 0) {
            int rlen = (len > 32-buflen) ? 32-buflen: len;

            if (rlen == 0) {
                buffer[31] = 0;
                fprintf(stderr, "socket_client_sendversion: "
                        "Response too long: (%s).\n", buffer);
                socket_client_close(1002);
                return;
            }

            if (socket_client_read_frame_data(buffer+buflen,
                                                rlen, maskkey) < 0) {
                socket_client_close(-1);
                return;
            }
            buflen += rlen;
            len -= rlen;
        }
    }

    if (buflen != 3 || strncmp(buffer, "VOK", 3)) {
        buffer[buflen == 32 ? 31 : buflen] = 0;
        fprintf(stderr, "socket_client_sendversion: "
                        "Invalid response: (%s).\n", buffer);
        socket_client_close(1002);
        return;
    }
}

/* Sends an error on a new client socket.
 * See socket_server_accept for a description of ok. */
static void socket_server_error(int newclient_fd, int ok) {
    char buffer[BUFFERSIZE];
    int len = 0;

    if ((ok & 0x01) &&
            (!(ok & 0x02) || !(ok & 0x7c))) {
        /* Path is not /, or / but clearly not a websocket handshake: 404 */
        len = snprintf(buffer, BUFFERSIZE,
                       "HTTP/1.1 404 Not Found\r\n"     \
                       "\r\n"                           \
                       "<h1>404 Not Found</h1>");
    } else if ((ok & 0x9F) == 0x9F && !(ok & 0x20)) {
        /* We received something that looks like a websocket handshake,
         * but wrong version */
        len = snprintf(buffer, BUFFERSIZE,
                       "HTTP/1.1 400 Bad Request\r\n"   \
                       "Sec-WebSocket-Version: 13\r\n"
                       "\r\n");
    } else {
        /* Generic answer */
        len = snprintf(buffer, BUFFERSIZE,
                       "HTTP/1.1 400 Bad Request\r\n"   \
                       "\r\n"                           \
                       "<h1>400 Bad Request</h1>");
    }

    if (verbose >= 3) {
        printf("socket_server_error: answer:\n");
        puts(buffer);
    }

    block_write(newclient_fd, buffer, len);

    close(newclient_fd);
}

/* Accept a new connection on the server socket. */
static void socket_server_accept() {
    int newclient_fd;
    struct sockaddr_in client_addr;
    unsigned int client_addr_len = sizeof(client_addr);
    char buffer[BUFFERSIZE];

    newclient_fd = accept(server_fd,
                          (struct sockaddr*)&client_addr, &client_addr_len);

    if (newclient_fd < 0) {
        perror("socket_server_accept: Error accepting new connection.\n");
        return;
    }

    int first = 1;
    /* bitmask indicating if we received everything we need in the header:
     *  - 0x01: GET {PATH} HTTP/1.1
     *  - 0x02: {PATH} == / in GET request
     *  - 0x04: Upgrade: websocket
     *  - 0x08: Connection: Upgrade
     *  - 0x10: Sec-WebSocket-Version: {VERSION}
     *  - 0x20: {VERSION} == 13
     *  - 0x40: Sec-WebSocket-Key: 24 bytes
     *  - 0x80: Host: localhost:PORT
     * Therefore, the correct final value is 0xFF
     */
    int ok = 0x00;

    /* 24 bytes from client (16 bytes base64 encoded), + 36 for GUID */
    char websocket_key[24+36];

    char* pbuffer = buffer;
    int n = read(newclient_fd, buffer, BUFFERSIZE);
    if (n <= 0) {
        perror("socket_server_accept: Cannot read from client");
        close(newclient_fd);
        return;
    }

    while (1) {
        /* Start of current line (until ':' for key-value pairs) */
        char* key = pbuffer;
        /* Star of value in current line (part after ': '). */
        char* value = NULL;

        while (1) {
            if (n == 0) {
                /* No more data in buffer: shift data so that key == buffer,
                 * and try reading again. */
                memmove(buffer, key, pbuffer-key);
                if (value) value -= (key-buffer);
                pbuffer -= (key-buffer);
                key = buffer;

                n = read(newclient_fd, pbuffer, BUFFERSIZE-(pbuffer-buffer));
                if (n <= 0) {
                    perror("socket_server_accept: Cannot read from client");
                    close(newclient_fd);
                    return;
                }
            }

            /* Detect new line:
             * HTTP RFC says it must be CRLF, but we accept LF. */
            if (*pbuffer == '\n') {
                if (*(pbuffer-1) == '\r')
                    *(pbuffer-1) = '\0';
                else
                    *pbuffer = '\0';
                n--; pbuffer++;
                break;
            }

            /* Detect Key: Value pairs */
            if (*pbuffer == ':' && !value) {
                value = pbuffer+2;
                *pbuffer = '\0';
            }

            n--; pbuffer++;
        }

        if (verbose >= 3)
            printf("socket_server_accept: "
                   "HTTP header: key=%s; value=%s\n", key, value);

        /* Empty line indicates end of header. */
        if (strlen(key) == 0 && !value) {
            break;
        }

        if (first) { /* Normally GET / HTTP/1.1 */
            first = 0;

            char* tok = strtok(key, " ");
            if (!tok || strcmp(tok, "GET")) {
                fprintf(stderr, "socket_server_accept: "
                        "Invalid HTTP method (%s).\n", tok);
                continue;
            }

            tok = strtok(NULL, " ");
            if (!tok || strcmp(tok, "/")) {
                fprintf(stderr, "socket_server_accept: "
                        "Invalid path (%s).\n", tok);
            } else {
                ok |= 0x02;
            }

            tok = strtok(NULL, " ");
            if (!tok || strcmp(tok, "HTTP/1.1")) {
                fprintf(stderr, "socket_server_accept: "
                        "Invalid HTTP version (%s).\n", tok);
                continue;
            }

            ok |= 0x01;
        } else {
            if (!value) {
                fprintf(stderr, "socket_server_accept: "
                        "Invalid HTTP header (%s).\n", key);
                socket_server_error(newclient_fd, 0x00);
                return;
            }

            if (!strcmp(key, "Upgrade") && !strcmp(value, "websocket")) {
                ok |= 0x04;
            } else if (!strcmp(key, "Connection") &&
                       !strcmp(value, "Upgrade")) {
                ok |= 0x08;
            } else if (!strcmp(key, "Sec-WebSocket-Version")) {
                ok |= 0x10;
                if (strcmp(value, "13")) {
                    fprintf(stderr, "socket_server_accept: "
                            "Invalid Sec-WebSocket-Version: %s\n", value);
                    continue;
                }
                ok |= 0x20;
            } else if (!strcmp(key, "Sec-WebSocket-Key")) {
                if (strlen(value) != 24) {
                    fprintf(stderr, "socket_server_accept: "
                            "Invalid Sec-WebSocket-Key: '%s'\n", value);
                    continue;
                }
                memcpy(websocket_key, value, 24);
                ok |= 0x40;
            } else if (!strcmp(key, "Host")) {
                char strbuf[32];
                snprintf(strbuf, 32, "localhost:%d", PORT);

                if (strcmp(value, strbuf)) {
                    fprintf(stderr, "socket_server_accept: "
                            "Invalid Host field: '%s'\n", value);
                    continue;
                }
                ok |= 0x80;
            }
        }
    }

    if (ok != 0xFF) {
        fprintf(stderr, "socket_server_accept: "
                "Some websocket headers missing (%x)\n", ok);
        socket_server_error(newclient_fd, ok);
        return;
    }

    if (verbose >= 1)
        printf("socket_server_accept: Header read successfully.\n");

    /* Compute response */
    char sha1[20];
    char b64[32];
    int i;

    memcpy(websocket_key+24, GUID, strlen(GUID));

    n = popen2("sha1sum", websocket_key, 24+36, buffer, BUFFERSIZE);

    /* SHA-1 is 20 bytes long (40 characters in hex form) */
    if (n < 40) {
        fprintf(stderr, "socket_server_accept: sha1sum response too short.\n");
        exit(1);
    }

    for (i = 0; i < 20; i++) {
        unsigned int value;
        n = sscanf(&buffer[i*2], "%02x", &value);
        if (n != 1) {
            fprintf(stderr, "socket_server_accept: "
                    "Cannot read SHA-1 sum (%s).\n", buffer);
            exit(1);
        }
        sha1[i] = (char)value;
    }

    n = popen2("base64", sha1, 20, b64, 32);
    /* base64 encoding of 20 bytes must be 28 bytes long (ceil(20/3*4)+1).
     * +1 for line feed */
    if (n != 29) {
        fprintf(stderr, "socket_server_accept: Invalid base64 response.\n");
        exit(1);
    }
    b64[28] = '\0';

    int len = snprintf(buffer, BUFFERSIZE,
                       "HTTP/1.1 101 Switching Protocols\r\n"   \
                       "Upgrade: websocket\r\n"                 \
                       "Connection: Upgrade\r\n"                \
                       "Sec-WebSocket-Accept: %s\r\n"           \
                       "\r\n", b64);

    if (len == BUFFERSIZE) {
        fprintf(stderr, "socket_server_accept: "
                "Response length > %d\n", BUFFERSIZE);
        exit(1);
    }

    if (verbose >= 3) {
        printf("socket_server_accept: HTTP response:\n");
        fwrite(buffer, 1, len, stdout);
    }

    n = block_write(newclient_fd, buffer, len);

    if (n < 0) {
        perror("socket_server_accept: Cannot write response");
        close(newclient_fd);
        return;
    }

    if (verbose >= 2)
        printf("socket_server_accept: Response sent\n");

    if (client_fd >= 0) {
        socket_client_close(1001); /* 1001: Going away */
    }

    client_fd = newclient_fd;

    socket_client_sendversion();

    return;
}

/* Initialise websocket server */
static void socket_server_init() {
    struct sockaddr_in server_addr;
    int optval;

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket_server_init: Cannot create server socket");
        exit(1);
    }

    /* SO_REUSEADDR to make sure the server can restart after a crash. */
    optval = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

    /* Listen on loopback interface, port PORT. */
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    server_addr.sin_port = htons(PORT);

    if (bind(server_fd,
             (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        perror("socket_server_init: Cannot bind server socket");
        exit(1);
    }

    if (listen(server_fd, 5) < 0) {
        perror("socket_server_init: Cannot listen on server socket");
        exit(1);
    }
}

static int terminate = 0;

static void signal_handler(int sig) {
    terminate = 1;
}

int main(int argc, char **argv) {
    int n;
    /* Poll array:
     * 0 - server_fd
     * 1 - pipein_fd
     * 2 - client_fd (if any)
     */
    static struct pollfd fds[3];
    int nfds = 3;
    sigset_t sigmask;
    sigset_t sigmask_orig;
    struct sigaction act;
    char c;

    while ((c = getopt(argc, argv, "v:")) != (char)-1) {
        switch (c) {
        case 'v':
            verbose = atoi(optarg);
            break;
        case '?':
            fprintf(stderr, "%s [-v 0-3]\n", argv[0]);
            return 1;
        default:
            abort();
        }
    }

    /* signal handler */
    memset(&act, 0, sizeof(act));
    act.sa_handler = signal_handler;

    if (sigaction(SIGHUP, &act, 0) < 0 ||
        sigaction(SIGINT, &act, 0) < 0 ||
        sigaction(SIGTERM, &act, 0) < 0) {
        perror("main: sigaction");
        return 2;
    }

    /* Ignore SIGPIPE in all cases */
    sigemptyset(&sigmask);
    sigaddset(&sigmask, SIGPIPE);

    if (sigprocmask(SIG_BLOCK, &sigmask, NULL) < 0) {
        perror("main: sigprocmask");
        return 2;
    }

    /* Ignore terminating signals except when ppoll is running */
    sigemptyset(&sigmask);
    sigaddset(&sigmask, SIGHUP);
    sigaddset(&sigmask, SIGINT);
    sigaddset(&sigmask, SIGTERM);

    if (sigprocmask(SIG_BLOCK, &sigmask, &sigmask_orig) < 0) {
        perror("main: sigprocmask");
        return 2;
    }

    /* Prepare pollfd structure. */
    memset(fds, 0, sizeof(fds));
    fds[0].events = POLLIN;
    fds[1].events = POLLIN;
    fds[2].events = POLLIN;

    /* Initialise pipe and WebSocket server */
    socket_server_init();
    pipe_init();

    while (!terminate) {
        /* Make sure fds is up to date. */
        fds[0].fd = server_fd;
        fds[1].fd = pipein_fd;
        fds[2].fd = client_fd;

        /* Only handle signals in ppoll: this makes sure we complete answering
         * the current request before bailing out. */
        n = ppoll(fds, nfds, NULL, &sigmask_orig);

        if (verbose >= 3)
            printf("main: poll ret=%d (%d, %d, %d)\n", n,
                   fds[0].revents, fds[1].revents, fds[2].revents);

        if (n < 0) {
            if (verbose >= 1)
                perror("main: ppoll error");
            break;
        }

        if (fds[0].revents & POLLIN) {
            if (verbose >= 1)
                printf("main: WebSocket accept\n");
            socket_server_accept();
            n--;
        }
        if (fds[1].revents & POLLIN) {
            if (verbose >= 2)
                printf("main: pipe fd ready\n");
            pipein_read();
            n--;
        }
        if (fds[2].revents & POLLIN) {
            if (verbose >= 2)
                printf("main: client fd ready\n");
            socket_client_read();
            n--;
        }

        if (n > 0) { /* Some events were not handled, this is a problem */
            fprintf(stderr, "main: some poll events could not be handled: "
                    "ret=%d (%d, %d, %d)\n",
                    n, fds[0].revents, fds[1].revents, fds[2].revents);
            break;
        }
    }

    if (verbose >= 1)
        printf("Terminating...\n");

    if (client_fd)
        socket_client_close(1001); /* Going away */

    return 0;
}
