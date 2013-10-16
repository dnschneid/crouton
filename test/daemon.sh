#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Monitors a web-based CSV queue for autotest requests, runs the test, and
# uploads the status and results.

# Example CSV contents (must be fully quoted):
#   "Timestamp","Repository","Branch","Additional parameters"
#   "2013/10/16 8:24:52 PM GMT","dnschneid/crouton","master",""

APPLICATION="${0##*/}"
SCRIPTDIR="`readlink -f "\`dirname "$0"\`/.."`"
QUEUEURL=''
SCPBASEOPTIONS='-BCqr'
SCPOPTIONS=''
UPLOADROOT="$HOME"

USAGE="$APPLICATION [options] -q QUEUEURL

Runs a daemon that polls a CSV on the internet for tests to run, and uploads
status and results to some destination via scp.

Options:
    -q QUEUEURL    Queue URL to poll for new test requests. Must be specified.
    -s SCPOPTIONS  Special options to pass to SCP in addition to $SCPBASEOPTIONS
                   Default: ${SCPOPTIONS:-"(nothing)"}
    -u UPLOADROOT  Base SCP-compatible URL directory to upload to. Must exist.
                   Default: $UPLOADROOT"

# Common functions
. "$SCRIPTDIR/installer/functions"

# Process arguments
while getopts 'q:s:u:' f; do
    case "$f" in
    q) QUEUEURL="$OPTARG";;
    s) SCPOPTIONS="$OPTARG";;
    u) UPLOADROOT="$OPTARG";;
    \?) error 2 "$USAGE";;
    esac
done
shift "$((OPTIND-1))"

if [ -z "$QUEUEURL" -o "$#" != 0 ]; then
    error 2 "$USAGE"
fi

# We need to run as root
if [ "$USER" != root -a "$UID" != 0 ]; then
    error 2 "$APPLICATION must be run as root."
fi

statusmonitor() {
    local machinestatus="$LOCALROOT/status-$id"
    echo -n '' > "$machinestatus"
    if [ -n "$CURTESTROOT" ]; then
        local teststatus="${CURTESTROOT%/}/status-$id"
        echo -n '' > "$teststatus"
        while read line; do
            echo "$line" >> "$machinestatus"
            echo "$line" >> "$teststatus"
            scp $SCPBASEOPTIONS $SCPOPTIONS \
                "$machinestatus" "$CURTESTROOT" "$UPLOADROOT"
        done
    else
        while read line; do
            echo "$line" >> "$machinestatus"
            scp $SCPBASEOPTIONS $SCPOPTIONS "$machinestatus" "$UPLOADROOT"
        done
    fi
}

# Get a consistent ID for the device in the form of board_xxxxxxxx
if hash vpd 2>/dev/null; then
    id="`awk -F= '/_RELEASE_BOARD=/ {print $2}' /etc/lsb-release`"
    id="${id%%-*}_`vpd -g serial_number | sha1sum | head -c 8`"
else
    # Oh well. Random testing ID it is.
    id="test_`hexdump -v -n4 -e '"" 1/1 "%02x"' /dev/urandom`"
fi

LOCALROOT="`mktemp -d --tmpdir='/tmp' 'crouton-autotest.XXX'`"
addtrap "rm -rf --one-file-system '$LOCALROOT'"

CURTESTROOT=''
echo 'Ready' | statusmonitor

CROUTONROOT="$LOCALROOT/crouton"

LASTFILE="$LOCALROOT/last"
echo "2 `date '+%s'`" > "$LASTFILE"

while sleep 10; do
    read lastline last < "$LASTFILE"
    # Grab the queue, skip to the next interesting line, convert field
    # boundaries into pipe characters, and then parse the result.
    (wget -qO- "$QUEUEURL" && echo) | tail -n"+$lastline" \
        | sed 's/^"//; s/","/|/g; s/"$//' | {
        while IFS='|' read date repo branch params _; do
            if [ -z "$date" ]; then
                continue
            fi
            lastline="$(($lastline+1))"
            # Convert to UNIX time and skip if it's an old request
            date="`date '+%s' --date="$date"`"
            if [ "$date" -le "$last" ]; then
                continue
            fi
            last="$date"

            # Validate the other fields
            branch="${branch%%/*}"
            gituser="${repo%%/*}"
            repo="${repo##*/}"
            tarball="https://github.com/$gituser/$repo/archive/$branch.tar.gz"

            # Test root should be consistent between machines
            date="`date -u '+%Y-%m-%d_%H-%M-%S' --date="@$date"`"
            paramsstr="${params:+"_"}`echo "$params" | tr ' [:punct:]' '_-'`"
            tname="${date}_${gituser}_${repo}_$branch$paramsstr"
            CURTESTROOT="$LOCALROOT/$tname"
            logdir="$CURTESTROOT/$id"
            mkdir -p "$logdir"

            # Start logging to the server
            {
                echo "Starting test $tname"
                mkdir -p "$CROUTONROOT"
                if wget -qO- "$tarball" \
                        | tar -C "$CROUTONROOT" -xz --strip-components=1; then
                    sh -e "$CROUTONROOT/test/run.sh" -l "$logdir" $params || true
                fi
                rm -rf --one-file-system "$CROUTONROOT"
            } 2>&1 | statusmonitor

            CURTESTROOT=''
            echo 'Ready' | statusmonitor
        done
        echo "$lastline $last" > "$LASTFILE"
    }
done
