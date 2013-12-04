/* Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * WebSocket server that provides an interface to an extension running in
 * Chromium OS.
 *
 * Mostly compliant with RFC 6455 - The WebSocket Protocol.
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
#include <sys/wait.h>
#include <errno.h>
#include <ctype.h>

const int BUFFERSIZE = 4096;

/* WebSocket constants */
#define VERSION "1"
const int PORT = 30001;
const int FRAMEMAXHEADERSIZE = 2+8;
const int MAXFRAMESIZE = 16*1048576; // 16MiB
const char* GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
/* Key from client must be 24 bytes long (16 bytes, base64 encoded) */
const int SECKEY_LEN = 24;
/* SHA-1 is 20 bytes long */
const int SHA1_LEN = 20;
/* base64-encoded SHA-1 must be 28 bytes long (ceil(20/3*4)+1). */
const int SHA1_BASE64_LEN = 28;

/* WebSocket opcodes */
const int WS_OPCODE_CONT = 0x0;
const int WS_OPCODE_TEXT = 0x1;
const int WS_OPCODE_BINARY = 0x2;
const int WS_OPCODE_CLOSE = 0x8;
const int WS_OPCODE_PING = 0x9;
const int WS_OPCODE_PONG = 0xA;

/* Pipe constants */
const char* PIPE_DIR = "/tmp/crouton-ext";
const char* PIPEIN_FILENAME = "/tmp/crouton-ext/in";
const char* PIPEOUT_FILENAME = "/tmp/crouton-ext/out";
const int PIPEOUT_WRITE_TIMEOUT = 3000;

/* 0 - Quiet
 * 1 - General messages (init, new connections)
 * 2 - 1 + Information on each transfer
 * 3 - 2 + Extra information */
static int verbose = 0;

#define log(level, str, ...) do { \
    if (verbose >= (level)) printf("%s: " str "\n", __func__, ##__VA_ARGS__); \
} while (0)

#define error(str, ...) printf("%s: " str "\n", __func__, ##__VA_ARGS__)

/* Similar to perror, but prints function name as well */
#define syserror(str, ...) printf("%s: " str " (%s)\n", \
                    __func__, ##__VA_ARGS__, strerror(errno))

/* File descriptors */
static int server_fd = -1;
static int pipein_fd = -1;
static int client_fd = -1;
static int pipeout_fd = -1;

/* Prototypes */
static int socket_client_write_frame(char* buffer, unsigned int size,
                                     unsigned int opcode, int fin);
static int socket_client_read_frame_header(int* fin, uint32_t* maskkey,
                                           int* length);
static int socket_client_read_frame_data(char* buffer, unsigned int size,
                                         uint32_t maskkey);
static void socket_client_close(int close_reason);

static void pipeout_close();

/**/
/* Helper functions */
/**/

/* Read exactly size bytes from fd, no matter how many reads it takes.
 * Returns size if successful, < 0 in case of error. */
static int block_read(int fd, char* buffer, size_t size) {
    int n;
    int tot = 0;

    while (tot < size) {
        n = read(fd, buffer+tot, size-tot);
        log(3, "n=%d+%d/%zd", n, tot, size);
        if (n < 0)
            return n;
        if (n == 0)
            return -1; /* EOF */
        tot += n;
    }

    return tot;
}

/* Write exactly size bytes from fd, no matter how many writes it takes.
 * Returns size if successful, < 0 in case of error. */
static int block_write(int fd, char* buffer, size_t size) {
    int n;
    int tot = 0;

    while (tot < size) {
        n = write(fd, buffer+tot, size-tot);
        log(3, "n=%d+%d/%zd", n, tot, size);
        if (n < 0)
            return n;
        if (n == 0)
            return -1;
        tot += n;
    }

    return tot;
}

/* Run external command, piping some data on its stdin, and reading back
 * the output. Returns the number of bytes read from the process (at most
 * outlen), or -1 on error. */
static int popen2(char* cmd, char* input, int inlen, char* output, int outlen) {
    pid_t pid = 0;
    int stdin_fd[2];
    int stdout_fd[2];
    int ret = -1;

    if (pipe(stdin_fd) < 0 || pipe(stdout_fd) < 0) {
        syserror("Failed to create pipe.");
        return -1;
    }

    pid = fork();

    if (pid < 0) {
        syserror("Fork error.");
        return -1;
    } else if (pid == 0) {
        /* Child: connect stdin/out to the pipes, close the unneeded halves */
        close(stdin_fd[1]);
        dup2(stdin_fd[0], STDIN_FILENO);
        close(stdout_fd[0]);
        dup2(stdout_fd[1], STDOUT_FILENO);

        execlp(cmd, cmd, NULL);

        error("Error running '%s'.", cmd);
        exit(1);
    }

    /* Parent */

    /* Write input, and read output, while waiting for process termination.
     * This could be done without polling, by reacting on SIGCHLD, but this is
     * good enough for our purpose, and slightly simpler. */
    struct pollfd fds[2];
    fds[0].events = POLLIN;
    fds[0].fd = stdout_fd[0];
    fds[1].events = POLLOUT;
    fds[1].fd = stdin_fd[1];

    pid_t wait_pid;
    int readlen = 0;
    int writelen = 0;
    while (1) {
        /* Get child status */
        wait_pid = waitpid(pid, NULL, WNOHANG);
        /* Check if there is data to read, no matter the process status. */
        /* Timeout after 10ms, or immediately if the process exited already */
        int polln = poll(fds, 2, (wait_pid == pid) ? 0 : 10);

        if (polln < 0) {
            syserror("poll error.");
            goto error;
        }

        log(3, "poll=%d (%d)", polln, (wait_pid == pid));

        /* We can write something to stdin */
        if (fds[1].revents & POLLOUT) {
            int n = write(stdin_fd[1], input+writelen, inlen-writelen);
            if (n < 0) {
                error("write error.");
                goto error;
            }
            log(3, "write n=%d/%d", n, inlen);

            writelen += n;
            if (writelen == inlen) {
                /* Done writing: Only poll stdout from now on. */
                close(stdin_fd[1]);
                stdin_fd[1] = -1;
                fds[1].fd = -1;
            }
            polln--;
        }

        /* We can read something from stdout */
        if (fds[0].revents & POLLIN) {
            int n = read(stdout_fd[0], output+readlen, outlen-readlen);
            if (n < 0) {
                error("read error.");
                goto error;
            }
            log(3, "read n=%d", n);

            readlen += n;
            if (readlen >= outlen) {
                error("Output too long.");
                ret = readlen;
                goto error;
            }
            polln--;
        }

        if (polln != 0) {
            error("Unknown poll event (%d).", fds[0].revents);
            goto error;
        }

        if (wait_pid == -1) {
            error("waitpid error.");
            goto error;
        } else if (wait_pid == pid) {
            log(3, "child exited!");
            break;
        }
    }

    if (stdin_fd[1] >= 0)
        close(stdin_fd[1]);
    close(stdout_fd[0]);
    return readlen;

error:
    if (stdin_fd[1] >= 0)
        close(stdin_fd[1]);
    /* Closing the stdout pipe forces the child process to exit */
    close(stdout_fd[0]);
    /* Try to wait 10ms for the process to exit, then bail out. */
    waitpid(pid, NULL, 10);
    return ret;
}

/* Open a pipe in non-blocking mode, then set it back to blocking mode. */
/* Returns fd on success, -1 if the pipe cannot be open, -2 if the O_NONBLOCK
 * flag cannot be cleared. */
static int pipe_open_block(const char* path, int oflag) {
    int fd;

    log(3, "%s", path);

    fd = open(path, oflag | O_NONBLOCK);
    if (fd < 0)
        return -1;

    /* Remove non-blocking flag */
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) < 0) {
        syserror("error in fnctl GETFL/SETFL.");
        close(fd);
        return -2;
    }

    return fd;
}

/**/
/* Pipe out functions */
/**/

/* Open the pipe out. Returns 0 on success, -1 on error. */
static int pipeout_open() {
    int i;

    log(2, "Opening pipe out...");

    /* Unfortunately, in the case where no reader is available (yet), opening
     * pipes for writing behaves as follows: In blocking mode, "open" blocks.
     * In non-blocking mode, it fails (returns -1). This means that we cannot
     * open the pipe, then use functions like poll/select to detect when a
     * reader becomes available. Waiting forever is also not an option: we do
     * want to block this server if a client "forgets" to read the answer back.
     * Therefore, we are forced to poll manually.
     * Using usleep is simpler, and probably better than measuring time elapsed:
     * If the system hangs for a while (like during large I/O writes), this will
     * still wait around PIPEOUT_WRITE_TIMEOUT ms of actual user time, instead
     * of clock time. */
    for (i = 0; i < PIPEOUT_WRITE_TIMEOUT/10; i++) {
        pipeout_fd = pipe_open_block(PIPEOUT_FILENAME, O_WRONLY);
        if (pipeout_fd >= 0)
            break;
        if (pipeout_fd == -2) /* fnctl error: this is fatal. */
            exit(1);
        usleep(10000);
    }

    if (pipeout_fd < 0) {
        error("Timeout while opening.");
        return -1;
    }

    return 0;
}

static void pipeout_close() {
    log(2, "Closing...");

    if (pipeout_fd < 0)
        return;

    close(pipeout_fd);
    pipeout_fd = -1;
}

static int pipeout_write(char* buffer, int len) {
    int n;

    log(3, "(fd=%d, len=%d)", pipeout_fd, len);

    if (pipeout_fd < 0)
        return -1;

    n = block_write(pipeout_fd, buffer, len);
    if (n != len) {
        error("Error writing to pipe.");
        pipeout_close();
    }
    return n;
}

/* Open pipe out, write a string, then close the pipe. */
static void pipeout_error(char* str) {
    pipeout_open();
    pipeout_write(str, strlen(str));
    pipeout_close();
}

/**/
/* Pipe in functions */
/**/

/* Flush the pipe (in case of error), close it, then reopen it. Reopening is
 * necessary to prevent poll from getting continuous POLLHUP when the process
 * that writes into the pipe terminates (croutonurlhandler for example).
 * This MUST be called before anything is written to pipeout to avoid race
 * condition, where we would flush out legitimate data from a second process */
static void pipein_reopen() {
    if (pipein_fd >= 0) {
        char buffer[BUFFERSIZE];
        while (read(pipein_fd, buffer, BUFFERSIZE) > 0);
        close(pipein_fd);
    }

    pipein_fd = pipe_open_block(PIPEIN_FILENAME, O_RDONLY);
    if (pipein_fd < 0) {
        syserror("Cannot open pipe in.");
        exit(1);
    }
}

/* Read data from the pipe, and forward it to the socket client. */
static void pipein_read() {
    int n;
    char buffer[FRAMEMAXHEADERSIZE+BUFFERSIZE];
    int first = 1;

    if (client_fd < 0) {
        log(1, "No client FD.");
        pipein_reopen();
        pipeout_error("EError: not connected.");
        return;
    }

    while (1) {
        n = read(pipein_fd, buffer+FRAMEMAXHEADERSIZE, BUFFERSIZE);
        log(3, "n=%d", n);

        if (n < 0) {
            /* This is very unlikely, and fatal. */
            syserror("Error reading from pipe.");
            exit(1);
        } else if (n == 0) {
            break;
        }

        /* Write a text frame for the first packet, then cont frames. */
        n = socket_client_write_frame(buffer, n,
                                  first ? WS_OPCODE_TEXT : WS_OPCODE_CONT, 0);
        if (n < 0) {
            error("Error writing frame.");
            pipein_reopen();
            pipeout_error("EError: socket write error.");
            return;
        }

        first = 0;
    }

    log(3, "EOF");

    pipein_reopen();

    /* Empty FIN frame to finish the message. */
    n = socket_client_write_frame(buffer, 0,
                                  first ? WS_OPCODE_TEXT : WS_OPCODE_CONT, 1);
    if (n < 0) {
        error("Error writing frame.");
        pipeout_error("EError: socket write error");
        return;
    }

    log(2, "Reading answer from client...");

    int fin = 0;
    uint32_t maskkey;
    int retry = 0;

    /* Ignore return value, so we still read the frame even if pipeout
     * cannot be open. */
    pipeout_open();

    /* Read possibly fragmented message from WebSocket. */
    while (fin != 1) {
        int len = socket_client_read_frame_header(&fin, &maskkey, &retry);

        log(3, "len=%d fin=%d retry=%d...", len, fin, retry);

        if (retry)
            continue;

        if (len < 0)
            break;

        /* Read the whole frame, and write it to pipeout */
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

/* Check if filename is a valid FIFO pipe. If not create it.
 * Returns 0 on success, -1 on error. */
int checkfifo(const char* filename) {
    struct stat fstat;

    /* Check if file exists: if not, create the FIFO. */
    if (access(filename, F_OK) < 0) {
        if (mkfifo(filename,
                S_IRUSR|S_IWUSR|S_IRGRP|S_IWGRP|S_IROTH|S_IWOTH) < 0) {
            syserror("Cannot create FIFO pipe.");
            return -1;
        }
        return 0;
    }

    /* We must be able to read and write the file. (only one direction is
     * necessary in croutonwebsocket, but croutonclip needs the other direction)
     */
    if (access(filename, R_OK|W_OK) < 0) {
        error("%s exists, but not readable and writable.",
                filename);
        return -1;
    }

    if (stat(filename, &fstat) < 0) {
        syserror("Cannot stat FIFO pipe.");
        return -1;
    }

    if (!S_ISFIFO(fstat.st_mode)) {
        error("%s exists, but is not a FIFO pipe.", filename);
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
            syserror("Cannot create FIFO pipe directory.");
            exit(1);
        }
    } else {
        if (stat(PIPE_DIR, &fstat) < 0) {
            syserror("Cannot stat FIFO pipe directory.");
            exit(1);
        }

        if (!S_ISDIR(fstat.st_mode)) {
            error("%s exists, but is not a directory.", PIPE_DIR);
            exit(1);
        }
    }

    if (checkfifo(PIPEIN_FILENAME) < 0 ||
        checkfifo(PIPEOUT_FILENAME) < 0) {
        /* checkfifo prints an error already. */
        exit(1);
    }

    pipein_reopen();
}

/**/
/* Websocket functions. */
/**/

/* Close the client socket, sending a close packet if sendclose is true. */
static void socket_client_close(int sendclose) {
    if (client_fd < 0)
        return;

    if (sendclose) {
        char buffer[FRAMEMAXHEADERSIZE];
        socket_client_write_frame(buffer, 0, WS_OPCODE_CLOSE, 1);
        /* FIXME: We are supposed to read back the answer (if we are not
         * replying to a close frame sent by the client), but we probably do not
         * want to block, waiting for the answer, so we just close the socket.
         */
    }

    close(client_fd);
    client_fd = -1;
}

/* Send a frame to the WebSocket client.
 *  - buffer needs to be FRAMEMAXHEADERSIZE+size long, and data must start at
 *    buffer[FRAMEMAXHEADERSIZE] only.
 *  - opcode should generally be WS_OPCODE_TEXT or WS_OPCODE_CONT (continuation)
 *  - fin indicates if the this is the last frame in the message
 * Returns size on success. On error, closes the socket, and returns -1.
 */
static int socket_client_write_frame(char* buffer, unsigned int size,
                                     unsigned int opcode, int fin) {
    /* Start of frame, with header: at least 2 bytes before the actual data */
    char* pbuffer = buffer+FRAMEMAXHEADERSIZE-2;
    int payloadlen = size;
    int extlensize = 0;

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
        int i;
        for (i = extlensize-1; i >= 0; i--) {
            pbuffer[2+i] = tmpsize & 0xff;
            tmpsize >>= 8;
        }
    }

    pbuffer[0] = opcode & 0x0f;
    if (fin) pbuffer[0] |= 0x80;
    pbuffer[1] = payloadlen; /* No mask (0x80) in server->client direction */

    int wlen = 2+extlensize+size;
    if (block_write(client_fd, pbuffer, wlen) != wlen) {
        syserror("Write error.");
        socket_client_close(0);
        return -1;
    }

    return size;
}

/* Read a WebSocket frame header:
 *  - fin indicates in this is the final frame in a fragmented message
 *  - maskkey is the XOR key used for the message
 *  - retry is set to 1 if we receive a control packet: the caller must call
 *    again if it expects more data.
 *
 * Returns the frame length on success. On error, closes the socket,
 * and returns -1.
 *
 * Data is then read with socket_client_read_frame_data()
 */
static int socket_client_read_frame_header(int* fin, uint32_t* maskkey,
                                           int* retry) {
    char header[2]; /* Minimum header length */
    char extlen[8]; /* Extended length */
    int n;

    *retry = 0;

    n = block_read(client_fd, header, 2);
    if (n != 2) {
        error("Read error.");
        socket_client_close(0);
        return -1;
    }

    int opcode, mask;
    uint64_t length;
    *fin = (header[0] & 0x80) != 0;
    if (header[0] & 0x70) { /* Reserved bits are on */
        error("Reserved bits are on.");
        socket_client_close(1);
        return -1;
    }
    opcode = header[0] & 0x0F;
    mask = (header[1] & 0x80) != 0;
    length = header[1] & 0x7F;

    log(2, "fin=%d; opcode=%d; mask=%d; length=%llu",
               *fin, opcode, mask, (long long unsigned int)length);

    /* Read extended length if necessary */
    int extlensize = 0;
    if (length == 126)
        extlensize = 2;
    else if (length == 127)
        extlensize = 8;

    if (extlensize > 0) {
        n = block_read(client_fd, extlen, extlensize);
        if (n != extlensize) {
            error("Read error.");
            socket_client_close(0);
            return -1;
        }

        /* Network-order (big-endian) */
        int i;
        length = 0;
        for (i = 0; i < extlensize; i++) {
            length = length << 8 | extlen[i];
        }

        log(3, "extended length=%llu", (long long unsigned int)length);
    }

    /* Read masking key if necessary */
    if (mask) {
        n = block_read(client_fd, (char*)maskkey, 4);
        if (n != 4) {
            error("Read error.");
            socket_client_close(0);
            return -1;
        }
    } else {
        /* RFC section 5.1 says we must close the connection if we receive a
         * frame that is not masked. */
        error("No mask set.");
        socket_client_close(1);
        return -1;
    }

    log(3, "maskkey=%04x", *maskkey);

    if (length > MAXFRAMESIZE) {
        error("Frame too big! (%llu>%d)\n",
                (long long unsigned int)length, MAXFRAMESIZE);
        socket_client_close(1);
        return -1;
    }

    /* is opcode continuation, text, or binary? */
    /* FIXME: We should check that only the first packet is text or binary, and
     * that the following are continuation ones. */
    if (opcode != WS_OPCODE_CONT &&
        opcode != WS_OPCODE_TEXT && opcode != WS_OPCODE_BINARY) {
        log(2, "Got a control packet (opcode=%d).", opcode);

        /* Control packets cannot be fragmented.
         * Unknown data (opcodes 3-7) will result in error anyway. */
        if (*fin == 0) {
            error("Fragmented unknown packet (%x).", opcode);
            socket_client_close(1);
            return -1;
        }

        /* Read the rest of the packet */
        char* buffer = malloc(length+3); /* +3 for unmasking safety */
        if (socket_client_read_frame_data(buffer, length, *maskkey) < 0) {
            socket_client_close(0);
            free(buffer);
            return -1;
        }

        if (opcode == WS_OPCODE_CLOSE) { /* Connection close. */
            error("Connection close from WebSocket client.");
            socket_client_close(1);
            free(buffer);
            return -1;
        } else if (opcode == WS_OPCODE_PING) { /* Ping */
            socket_client_write_frame(buffer, length, WS_OPCODE_PONG, 1);
        } else if (opcode == WS_OPCODE_PONG) { /* Pong */
            /* Do nothing */
        } else { /* Unknown opcode */
            error("Unknown packet (%x).", opcode);
            socket_client_close(1);
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

/* Read frame data from the WebSocket client:
 * - Make sure that buffer is at least 4*ceil(size/4) long, as unmasking works
 *   on blocks of 4 bytes.
 * Returns size on success (the buffer has been completely filled).
 * On error, closes the socket, and returns -1.
 */
static int socket_client_read_frame_data(char* buffer, unsigned int size,
                                         uint32_t maskkey) {
    int n = block_read(client_fd, buffer, size);
    if (n != size) {
        error("Read error.");
        socket_client_close(0);
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

/* Unrequested data came in from WebSocket client. */
static void socket_client_read() {
    char buffer[BUFFERSIZE];
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
                /* We only got a control frame, go back to main loop. We will
                 * get called again if there is more data waiting. */
                return;
            } else {
                /* We already read some frames of a fragmented message: wait
                 * for the rest. */
                continue;
            }
        }

        if (curlen < 0) {
            socket_client_close(0);
            return;
        }

        if (length+curlen > BUFFERSIZE) {
            error("Message too big (%d>%d).", length+curlen, BUFFERSIZE);
            socket_client_close(1);
            return;
        }

        if (socket_client_read_frame_data(buffer+length, curlen, maskkey) < 0) {
            error("Read error.");
            socket_client_close(0);
            return;
        }

        length += curlen;
        data = 1;
    }

    /* In future versions, we can process such packets here. */

    /* In the current version, this is actually never supposed to happen:
     * close the connection */
    error("Received an unexpected packet from client.");
    socket_client_close(0);
}

/* Send a version packet to the extension, and read VOK reply. */
static void socket_client_sendversion() {
    char* version = "V"VERSION;
    int versionlen = strlen(version);
    char* outbuf = malloc(FRAMEMAXHEADERSIZE+versionlen);
    memcpy(outbuf+FRAMEMAXHEADERSIZE, version, versionlen);

    log(2, "Sending version packet (%s).", version);

    if (socket_client_write_frame(outbuf, versionlen, WS_OPCODE_TEXT, 1) < 0) {
        error("Write error.");
        socket_client_close(0);
        free(outbuf);
        return;
    }
    free(outbuf);

    /* Read response back */
    char buffer[256];
    int buflen = 0;
    int fin = 0;
    uint32_t maskkey;
    int retry = 0;

    /* Read possibly fragmented message from WebSocket. */
    while (fin != 1) {
        int len = socket_client_read_frame_header(&fin, &maskkey, &retry);

        if (retry)
            continue;

        if (len < 0)
            break;

        if (len+buflen > 256) {
            error("Response too long: (>%d bytes).", 256);
            socket_client_close(1);
            return;
        }

        if (socket_client_read_frame_data(buffer+buflen, len, maskkey) < 0) {
            socket_client_close(0);
            return;
        }
        buflen += len;
    }

    buffer[buflen == 256 ? 255 : buflen] = 0;
    if (buflen != 3 || strcmp(buffer, "VOK")) {
        int i;
        for (i = 0; i < buflen; i++) {
            if (!isprint(buffer[i]))
                buffer[i] = '?';
        }
        error("Invalid response: %s.", buffer);
        socket_client_close(1);
        return;
    }

    log(2, "Received VOK.");
}

/* Bitmask indicating if we received everything we need in the header */
const int OK_GET = 0x01;         /* GET {PATH} HTTP/1.1 */
const int OK_GET_PATH = 0x02;    /* {PATH} == / in GET request */
const int OK_UPGRADE = 0x04;     /* Upgrade: websocket */
const int OK_CONNECTION = 0x08;  /* Connection: Upgrade */
const int OK_SEC_VERSION = 0x10; /* Sec-WebSocket-Version: {VERSION} */
const int OK_VERSION = 0x20;     /* {VERSION} == 13 */
const int OK_SEC_KEY = 0x40;     /* Sec-WebSocket-Key: 24 bytes */
const int OK_HOST = 0x80;        /* Host: localhost:PORT */
const int OK_ALL = 0xFF;         /* Final correct value is 0xFF */

/* Send an error on a new client socket, then close the socket. */
static void socket_server_error(int newclient_fd, int ok) {
    /* Values found only in WebSocket header */
    const int OK_WEBSOCKET = OK_UPGRADE|OK_CONNECTION|OK_SEC_VERSION|
                             OK_VERSION|OK_SEC_KEY;
    /* Values found in WebSocket header of a possibly wrong version */
    const int OK_OTHER_VERSION = OK_GET|OK_UPGRADE|OK_CONNECTION|OK_SEC_VERSION;

    char buffer[BUFFERSIZE];

    if ((ok & OK_GET) &&
            (!(ok & OK_GET_PATH) || !(ok & OK_WEBSOCKET))) {
        /* Path is not /, or / but clearly not a WebSocket handshake: 404 */
        strncpy(buffer,
                "HTTP/1.1 404 Not Found\r\n"
                "\r\n"
                "<h1>404 Not Found</h1>", BUFFERSIZE);
    } else if ((ok & OK_OTHER_VERSION) == OK_OTHER_VERSION &&
               !(ok & OK_VERSION)) {
        /* We received something that looks like a WebSocket handshake,
         * but wrong version */
        strncpy(buffer,
                "HTTP/1.1 400 Bad Request\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "\r\n", BUFFERSIZE);
    } else {
        /* Generic answer */
        strncpy(buffer,
                "HTTP/1.1 400 Bad Request\r\n"
                "\r\n"
                "<h1>400 Bad Request</h1>", BUFFERSIZE);
    }

    log(3, "answer:\n%s===", buffer);

    /* Ignore errors */
    block_write(newclient_fd, buffer, strlen(buffer));

    close(newclient_fd);
}

/* Read and parse HTTP header.
 * Returns 0 if the header is valid. websocket_key must be at least SECKEY_LEN
 * bytes long, and contains the value of Sec-WebSocket-Key on success.
 * Returns < 0 in case of error: in that case newclient_fd is closed.
 */
static int socket_server_read_header(int newclient_fd, char* websocket_key) {
    int first = 1;
    char buffer[BUFFERSIZE];
    int ok = 0x00;

    char* pbuffer = buffer;
    int n = read(newclient_fd, buffer, BUFFERSIZE);
    if (n <= 0) {
        syserror("Cannot read from client.");
        close(newclient_fd);
        return -1;
    }

    while (1) {
        /* Start of current line (until ':' for key-value pairs) */
        char* key = pbuffer;
        /* Start of value in current line (part after ': '). */
        char* value = NULL;

        /* Read a line of header, splitting key-value pairs if possible. */
        while (1) {
            if (n == 0) {
                /* No more data in buffer: shift data so that key == buffer,
                 * and try reading again. */
                memmove(buffer, key, pbuffer-key);
                if (value)
                    value -= (key-buffer);
                pbuffer -= (key-buffer);
                key = buffer;

                n = read(newclient_fd, pbuffer, BUFFERSIZE-(pbuffer-buffer));
                if (n <= 0) {
                    syserror("Cannot read from client.");
                    close(newclient_fd);
                    return -1;
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

            /* Detect "Key: Value" pairs, on all lines but the first one. */
            if (!first && !value && *pbuffer == ':') {
                value = pbuffer+2;
                *pbuffer = '\0';
            }

            n--; pbuffer++;
        }

        log(3, "HTTP header: key=%s; value=%s.", key, value);

        /* Empty line indicates end of header. */
        if (strlen(key) == 0 && !value)
            break;

        if (first) { /* Normally GET / HTTP/1.1 */
            first = 0;

            char* tok = strtok(key, " ");
            if (!tok || strcmp(tok, "GET")) {
                error("Invalid HTTP method (%s).", tok);
                continue;
            }

            tok = strtok(NULL, " ");
            if (!tok || strcmp(tok, "/")) {
                error("Invalid path (%s).", tok);
            } else {
                ok |= OK_GET_PATH;
            }

            tok = strtok(NULL, " ");
            if (!tok || strcmp(tok, "HTTP/1.1")) {
                error("Invalid HTTP version (%s).", tok);
                continue;
            }

            ok |= OK_GET;
        } else {
            if (!value) {
                error("Invalid HTTP header (%s).", key);
                socket_server_error(newclient_fd, 0x00);
                return -1;
            }

            if (!strcmp(key, "Upgrade") && !strcmp(value, "websocket")) {
                ok |= OK_UPGRADE;
            } else if (!strcmp(key, "Connection") &&
                       !strcmp(value, "Upgrade")) {
                ok |= OK_CONNECTION;
            } else if (!strcmp(key, "Sec-WebSocket-Version")) {
                ok |= OK_SEC_VERSION;
                if (strcmp(value, "13")) {
                    error("Invalid Sec-WebSocket-Version: '%s'.", value);
                    continue;
                }
                ok |= OK_VERSION;
            } else if (!strcmp(key, "Sec-WebSocket-Key")) {
                if (strlen(value) != SECKEY_LEN) {
                    error("Invalid Sec-WebSocket-Key: '%s'.", value);
                    continue;
                }
                memcpy(websocket_key, value, SECKEY_LEN);
                ok |= OK_SEC_KEY;
            } else if (!strcmp(key, "Host")) {
                char strbuf[32];
                snprintf(strbuf, 32, "localhost:%d", PORT);

                if (strcmp(value, strbuf)) {
                    error("Invalid Host field: '%s'.", value);
                    continue;
                }
                ok |= OK_HOST;
            }
        }
    }

    if (ok != OK_ALL) {
        error("Some WebSocket headers missing (%x).", ~ok & OK_ALL);
        socket_server_error(newclient_fd, ok);
        return -1;
    }

    return 0;
}

/* Accept a new client connection on the server socket. */
static void socket_server_accept() {
    int newclient_fd;
    struct sockaddr_in client_addr;
    unsigned int client_addr_len = sizeof(client_addr);
    char buffer[BUFFERSIZE];

    newclient_fd = accept(server_fd,
                          (struct sockaddr*)&client_addr, &client_addr_len);

    if (newclient_fd < 0) {
        syserror("Error accepting new connection.");
        return;
    }

    /* key from client + GUID */
    int websocket_keylen = SECKEY_LEN+strlen(GUID);
    char websocket_key[websocket_keylen];

    /* Read and parse HTTP header */
    if (socket_server_read_header(newclient_fd, websocket_key) < 0) {
        return;
    }

    log(1, "Header read successfully.");

    /* Compute sha1+base64 response (RFC section 4.2.2, paragraph 5.4) */

    char sha1[SHA1_LEN];

    /* Some margin so we can read the full output of base64 */
    int b64_len = SHA1_BASE64_LEN+4;
    char b64[b64_len];
    int i;

    memcpy(websocket_key+SECKEY_LEN, GUID, strlen(GUID));

    /* SHA-1 is 20 bytes long (40 characters in hex form) */
    if (popen2("sha1sum", websocket_key, websocket_keylen,
               buffer, BUFFERSIZE) < 2*SHA1_LEN) {
        error("sha1sum response too short.");
        exit(1);
    }

    for (i = 0; i < SHA1_LEN; i++) {
        unsigned int value;
        if (sscanf(&buffer[i*2], "%02x", &value) != 1) {
            buffer[2*SHA1_LEN] = 0;
            error("Cannot read SHA-1 sum (%s).", buffer);
            exit(1);
        }
        sha1[i] = (char)value;
    }

    /* base64 encoding of SHA1_LEN bytes must be SHA1_BASE64_LEN bytes long.
     * Either the output is exactly SHA1_BASE64_LEN long, or the last character
     * is a line feed (RFC 3548 forbids other characters in output) */
    int n = popen2("base64", sha1, SHA1_LEN, b64, b64_len);
    if (n < SHA1_BASE64_LEN ||
            (n != SHA1_BASE64_LEN && b64[SHA1_BASE64_LEN] != '\r' &&
             b64[SHA1_BASE64_LEN] != '\n')) {
        error("Invalid base64 response.");
        exit(1);
    }
    b64[SHA1_BASE64_LEN] = '\0';

    int len = snprintf(buffer, BUFFERSIZE,
                       "HTTP/1.1 101 Switching Protocols\r\n"
                       "Upgrade: websocket\r\n"
                       "Connection: Upgrade\r\n"
                       "Sec-WebSocket-Accept: %s\r\n"
                       "\r\n", b64);

    if (len == BUFFERSIZE) {
        error("Response length > %d.", BUFFERSIZE);
        exit(1);
    }

    log(3, "HTTP response:\n%s===", buffer);

    if (block_write(newclient_fd, buffer, len) != len) {
        syserror("Cannot write response.");
        close(newclient_fd);
        return;
    }

    log(2, "Response sent.");

    /* Close existing connection, if any. */
    if (client_fd >= 0)
        socket_client_close(1);

    client_fd = newclient_fd;

    socket_client_sendversion();

    return;
}

/* Initialise WebSocket server */
static void socket_server_init() {
    struct sockaddr_in server_addr;
    int optval;

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        syserror("Cannot create server socket.");
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
        syserror("Cannot bind server socket.");
        exit(1);
    }

    if (listen(server_fd, 5) < 0) {
        syserror("Cannot listen on server socket.");
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
    struct pollfd fds[3];
    int nfds = 3;
    sigset_t sigmask;
    sigset_t sigmask_orig;
    struct sigaction act;
    int c;

    while ((c = getopt(argc, argv, "v:")) != -1) {
        switch (c) {
        case 'v':
            verbose = atoi(optarg);
            break;
        default:
            fprintf(stderr, "%s [-v 0-3]\n", argv[0]);
            return 1;
        }
    }

    /* Termination signal handler. */
    memset(&act, 0, sizeof(act));
    act.sa_handler = signal_handler;

    if (sigaction(SIGHUP, &act, 0) < 0 ||
        sigaction(SIGINT, &act, 0) < 0 ||
        sigaction(SIGTERM, &act, 0) < 0) {
        syserror("sigaction error.");
        return 2;
    }

    /* Ignore SIGPIPE in all cases: it may happen, since we write to pipes, but
     * it is not fatal. */
    sigemptyset(&sigmask);
    sigaddset(&sigmask, SIGPIPE);

    if (sigprocmask(SIG_BLOCK, &sigmask, NULL) < 0) {
        syserror("sigprocmask error.");
        return 2;
    }

    /* Ignore terminating signals, except when ppoll is running. Save current
     * mask in sigmask_orig. */
    sigemptyset(&sigmask);
    sigaddset(&sigmask, SIGHUP);
    sigaddset(&sigmask, SIGINT);
    sigaddset(&sigmask, SIGTERM);

    if (sigprocmask(SIG_BLOCK, &sigmask, &sigmask_orig) < 0) {
        syserror("sigprocmask error.");
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

        /* Only handle signals in ppoll: this makes sure we complete processing
         * the current request before bailing out. */
        n = ppoll(fds, nfds, NULL, &sigmask_orig);

        log(3, "poll ret=%d (%d, %d, %d)\n", n,
                   fds[0].revents, fds[1].revents, fds[2].revents);

        if (n < 0) {
            /* Do not print error when ppoll is interupted by a signal. */
            if (errno != EINTR || verbose >= 1)
                syserror("ppoll error.");
            break;
        }

        if (fds[0].revents & POLLIN) {
            log(1, "WebSocket accept.");
            socket_server_accept();
            n--;
        }
        if (fds[1].revents & POLLIN) {
            log(2, "Pipe fd ready.");
            pipein_read();
            n--;
        }
        if (fds[2].revents & POLLIN) {
            log(2, "Client fd ready.");
            socket_client_read();
            n--;
        }

        if (n > 0) { /* Some events were not handled, this is a problem */
            error("Some poll events could not be handled: "
                    "ret=%d (%d, %d, %d).",
                    n, fds[0].revents, fds[1].revents, fds[2].revents);
            break;
        }
    }

    log(1, "Terminating...");

    if (client_fd)
        socket_client_close(1);

    return 0;
}
