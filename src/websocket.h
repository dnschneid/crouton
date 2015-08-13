/* Copyright (c) 2015 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Provides common WebSocket functions that can be used by both websocket.c
 * and fbserver.c.
 *
 * Mostly compliant with RFC 6455 - The WebSocket Protocol.
 *
 * Things that are supported, but not tested:
 *  - Fragmented packets from client
 *  - Ping packets
 */

#define _GNU_SOURCE /* for ppoll */
#include <ctype.h>
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <netinet/in.h>
#include <sys/wait.h>

const int BUFFERSIZE = 4096;

/* WebSocket constants */
const int FRAMEMAXHEADERSIZE = 16; // Actually 2+8, but align on 8-byte boundary
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

/* WebSocket bitmasks */
const char WS_HEADER0_FIN = 0x80;  /* fin */
const char WS_HEADER0_RSV = 0x70;  /* reserved */
const char WS_HEADER0_OPCODE_MASK = 0x0F;  /* opcode */
const char WS_HEADER1_MASK = 0x80;  /* mask */
const char WS_HEADER1_LEN_MASK = 0x7F;  /* payload length */

/* 0 - Quiet
 * 1 - General messages (init, new connections)
 * 2 - 1 + Information on each transfer
 * 3 - 2 + Extra information */
static int verbose = 0;

#define log(level, str, ...) do { \
    if (verbose >= (level)) printf("%s: " str "\n", __func__, ##__VA_ARGS__); \
} while (0)

#define error(str, ...) printf("%s: " str "\n", __func__, ##__VA_ARGS__)

/* Aborts if expr is false */
#define trueorabort(expr, str, ...) do { \
    if (!(expr)) { \
        printf("%s: ASSERTION " #expr " FAILED (" str ")\n", \
               __func__, ##__VA_ARGS__);                     \
        abort(); \
    }            \
} while (0)

/* Similar to perror, but prints function name as well */
#define syserror(str, ...) printf("%s: " str " (%s)\n", \
                    __func__, ##__VA_ARGS__, strerror(errno))

/* Port number, assigned in socket_server_init() */
static int port = -1;

/* File descriptors */
static int server_fd = -1;
static int client_fd = -1;

/* Prototypes */
static int socket_client_write_frame(char* buffer, unsigned int size,
                                     unsigned int opcode, int fin);
static int socket_client_read_frame_header(int* fin, uint32_t* maskkey,
                                           int* length);
static int socket_client_read_frame_data(char* buffer, unsigned int size,
                                         uint32_t maskkey);
static void socket_client_close(int close_reason);

/**/
/* Helper functions */
/**/

/* Read exactly size bytes from fd, no matter how many reads it takes.
 * Returns size if successful, < 0 in case of error. */
static int block_read(int fd, char* buffer, size_t size) {
    int n;
    int tot = 0;

    while (tot < size) {
        n = read(fd, buffer + tot, size - tot);
        log(3, "n=%d+%d/%zd", n, tot, size);
        if (n < 0)
            return n;
        if (n == 0)
            return -1;  /* EOF */
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
        n = write(fd, buffer + tot, size - tot);
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
 * outlen), or a negative number on error (-exit status). */
static int popen2(char* cmd, char *const argv[],
                  char* input, int inlen, char* output, int outlen) {
    pid_t pid = 0;
    int stdin_fd[2];
    int stdout_fd[2];

    if (pipe(stdin_fd) < 0 || pipe(stdout_fd) < 0) {
        syserror("Failed to create pipe.");
        return -1;
    }

    log(3, "pipes: in %d/%d; out %d/%d",
           stdin_fd[0], stdin_fd[1], stdout_fd[0], stdout_fd[1]);

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

        if (argv) {
            execvp(cmd, argv);
        } else {
            execlp(cmd, cmd, NULL);
        }

        syserror("Error running '%s'.", cmd);
        exit(127);
    }

    /* Parent */

    /* Close uneeded halves (those are used by the child) */
    close(stdin_fd[0]);
    close(stdout_fd[1]);

    /* Write input, and read output. We rely on POLLHUP getting set on stdout
     * when the process exits (this assumes the process does not do anything
     * strange like closing stdout and staying alive). */
    struct pollfd fds[2];
    fds[0].events = POLLIN;
    fds[0].fd = stdout_fd[0];
    fds[1].events = POLLOUT;
    fds[1].fd = stdin_fd[1];

    int readlen = 0; /* Also acts as return value */
    int writelen = 0;
    while (1) {
        int polln = poll(fds, 2, -1);

        if (polln < 0) {
            syserror("poll error.");
            readlen = -1;
            break;
        }

        log(3, "poll=%d", polln);

        /* We can write something to stdin */
        if (fds[1].revents & POLLOUT) {
            if (inlen > writelen) {
                int n = write(stdin_fd[1], input + writelen, inlen - writelen);
                if (n < 0) {
                    error("write error.");
                    readlen = -1;
                    break;
                }
                log(3, "write n=%d/%d", n, inlen);
                writelen += n;
            }

            if (writelen == inlen) {
                /* Done writing: Only poll stdout from now on. */
                close(stdin_fd[1]);
                stdin_fd[1] = -1;
                fds[1].fd = -1;
            }
            fds[1].revents &= ~POLLOUT;
        }

        if (fds[1].revents != 0) {
            error("Unknown poll event on stdout (%d).", fds[1].revents);
            readlen = -1;
            break;
        }

        /* We can read something from stdout */
        if (fds[0].revents & POLLIN) {
            int n = read(stdout_fd[0], output + readlen, outlen - readlen);
            if (n < 0) {
                error("read error.");
                readlen = -1;
                break;
            }
            log(3, "read n=%d", n);
            readlen += n;

            if (verbose >= 3) {
                fwrite(output, 1, readlen, stdout);
            }

            if (readlen >= outlen) {
                error("Output too long.");
                break;
            }
            fds[0].revents &= ~POLLIN;
        }

        /* stdout has hung up (process terminated) */
        if (fds[0].revents == POLLHUP) {
            log(3, "pollhup");
            break;
        } else if (fds[0].revents != 0) {
            error("Unknown poll event on stdin (%d).", fds[0].revents);
            readlen = -1;
            break;
        }
    }

    if (stdin_fd[1] >= 0)
        close(stdin_fd[1]);
    /* Closing the stdout pipe forces the child process to exit */
    close(stdout_fd[0]);

    /* Get child status (no timeout: we assume the child behaves well) */
    int status = 0;
    pid_t wait_pid = waitpid(pid, &status, 0);

    if (wait_pid != pid) {
        syserror("waitpid error.");
        return -1;
    }

    if (WIFEXITED(status)) {
        log(3, "child exited!");
        if (WEXITSTATUS(status) != 0) {
            error("child exited with status %d", WEXITSTATUS(status));
            return -WEXITSTATUS(status);
        }
    } else {
        error("child process did not exit: %d", status);
        return -1;
    }

    if (writelen != inlen) {
        error("Incomplete write.");
        return -1;
    }

    return readlen;
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
    char* pbuffer = buffer + FRAMEMAXHEADERSIZE - 2;
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

    pbuffer[0] = opcode & WS_HEADER0_OPCODE_MASK;
    if (fin) pbuffer[0] |= WS_HEADER0_FIN;
    pbuffer[1] = payloadlen;  /* No mask (0x80) in server->client direction */

    int wlen = 2 + extlensize + size;
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
    *fin = (header[0] & WS_HEADER0_FIN) != 0;
    if (header[0] & WS_HEADER0_RSV) {
        error("Reserved bits are on.");
        socket_client_close(1);
        return -1;
    }
    opcode = header[0] & WS_HEADER0_OPCODE_MASK;
    mask = (header[1] & WS_HEADER1_MASK) != 0;
    length = header[1] & WS_HEADER1_LEN_MASK;

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
            length = length << 8 | (uint8_t)extlen[i];
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

        if (opcode == WS_OPCODE_CLOSE) {  /* Connection close. */
            error("Connection close from WebSocket client.");
            socket_client_close(1);
            free(buffer);
            return -1;
        } else if (opcode == WS_OPCODE_PING) {  /* Ping */
            socket_client_write_frame(buffer, length, WS_OPCODE_PONG, 1);
        } else if (opcode == WS_OPCODE_PONG) {  /* Pong */
            /* Do nothing */
        } else {  /* Unknown opcode */
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

/* Read a complete frame from the WebSocket client:
 * - Make sure that buffer size is a multiple of 4 (for unmasking).
 * Returns packet size on success.
 * On error (e.g. packet too large for buffer), closes the socket, and
 * returns -1.
 */
static int socket_client_read_frame(char* buffer, int size) {
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
            return -1;

        if (len+buflen > size) {
            error("Response too long: (>%d bytes).", size);
            socket_client_close(1);
            return -1;
        }

        if (socket_client_read_frame_data(buffer + buflen, len, maskkey) < 0) {
            socket_client_close(0);
            return -1;
        }
        buflen += len;
    }

    return buflen;
}

/* Send a version packet to the extension, and read VOK reply. */
static int socket_client_sendversion(char* version) {
    int versionlen = strlen(version);
    char* outbuf = malloc(FRAMEMAXHEADERSIZE + versionlen);
    memcpy(outbuf + FRAMEMAXHEADERSIZE, version, versionlen);

    log(2, "Sending version packet (%s).", version);

    if (socket_client_write_frame(outbuf, versionlen, WS_OPCODE_TEXT, 1) < 0) {
        error("Write error.");
        socket_client_close(0);
        free(outbuf);
        return -1;
    }
    free(outbuf);

    /* Read response back */
    char buffer[256];
    int buflen = socket_client_read_frame(buffer, sizeof(buffer));

    buffer[buflen == 256 ? 255 : buflen] = 0;
    if (buflen != 3 || strcmp(buffer, "VOK")) {
        int i;
        for (i = 0; i < buflen; i++) {
            if (!isprint(buffer[i]))
                buffer[i] = '?';
        }
        error("Invalid response: %s.", buffer);
        socket_client_close(1);
        return -1;
    }

    log(2, "Received VOK.");
    return 0;
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

        if (first) {  /* Normally GET / HTTP/1.1 */
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
                snprintf(strbuf, 32, "localhost:%d", port);

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
static int socket_server_accept(char* version) {
    int newclient_fd;
    struct sockaddr_in client_addr;
    unsigned int client_addr_len = sizeof(client_addr);
    char buffer[BUFFERSIZE];

    newclient_fd = accept(server_fd,
                          (struct sockaddr*)&client_addr, &client_addr_len);

    if (newclient_fd < 0) {
        syserror("Error accepting new connection.");
        return -1;
    }

    /* key from client + GUID */
    int websocket_keylen = SECKEY_LEN + strlen(GUID);
    char websocket_key[websocket_keylen];

    /* Read and parse HTTP header */
    if (socket_server_read_header(newclient_fd, websocket_key) < 0) {
        return -1;
    }

    log(1, "Header read successfully.");

    /* Compute sha1+base64 response (RFC section 4.2.2, paragraph 5.4) */

    char sha1[SHA1_LEN];

    /* Some margin so we can read the full output of base64 */
    int b64_len = SHA1_BASE64_LEN + 4;
    char b64[b64_len];
    int i;

    memcpy(websocket_key + SECKEY_LEN, GUID, strlen(GUID));

    /* SHA-1 is 20 bytes long (40 characters in hex form) */
    if (popen2("sha1sum", NULL, websocket_key, websocket_keylen,
               buffer, BUFFERSIZE) < 2*SHA1_LEN) {
        error("sha1sum response too short.");
        exit(1);
    }

    /* Make sure sscanf does not read too much data */
    buffer[2*SHA1_LEN + 1] = '\0';
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
    int n = popen2("base64", NULL, sha1, SHA1_LEN, b64, b64_len);
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
        return -1;
    }

    log(2, "Response sent.");

    /* Close existing connection, if any. */
    if (client_fd >= 0)
        socket_client_close(1);

    client_fd = newclient_fd;

    return socket_client_sendversion(version);
}

/* Initialise WebSocket server */
static void socket_server_init(int port_) {
    struct sockaddr_in server_addr;
    int optval;

    port = port_;

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
    server_addr.sin_port = htons(port);

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
