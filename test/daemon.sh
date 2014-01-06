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
LOGUPLOADINTERVAL=60
POLLINTERVAL=10
READYPINGINTERVAL=600
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

statusmonitor() { (
    local machinestatus="$LOCALROOT/status-$id"
    if [ -n "$CURTESTROOT" ]; then
        local sig='USR1'
        local teststatus="${CURTESTROOT%/}/status-$id"
        local uploadcmd="scp $SCPBASEOPTIONS $SCPOPTIONS \
                             '$machinestatus' '$CURTESTROOT' '$UPLOADROOT'"
        echo -n '' > "$machinestatus"
        echo -n '' > "$teststatus"
        trap '' "$sig"
        (
            updatetime=0
            while sleep 1; do
                if [ "$updatetime" = 0 ]; then
                    trap '' "$sig"
                    eval "$uploadcmd"
                    trap "$uploadcmd" "$sig"
                    updatetime="$LOGUPLOADINTERVAL"
                else
                    updatetime="$(($updatetime-1))"
                fi
            done
        ) &
        uploader="$!"
        settrap "kill '$uploader' 2>/dev/null;"
        while read line; do
            echo "$line" >> "$machinestatus"
            echo "$line" >> "$teststatus"
            kill -"$sig" "$uploader"
        done
        kill "$uploader"
        wait "$uploader" || true
        eval "$uploadcmd"
    else
        sed "s/^READY/READY ` \
            dbus-send --system --type=method_call --print-reply \
                  --dest=org.chromium.UpdateEngine /org/chromium/UpdateEngine \
                  org.chromium.UpdateEngineInterface.GetStatus 2>/dev/null \
            | awk -F'"' '/UPDATE_STATUS/ {print $2; exit}'`/" > "$machinestatus"
        scp $SCPBASEOPTIONS $SCPOPTIONS "$machinestatus" "$UPLOADROOT"
    fi
) }

# Get a consistent ID for the device in the form of board-channel_xxxxxxxx
if hash vpd 2>/dev/null; then
    id="`awk '/_RELEASE_DESCRIPTION=/{print $NF "-" $(NF-1)}' /etc/lsb-release`"
    id="${id%"-channel"}_`vpd -g serial_number | sha1sum | head -c 8`"
else
    # Oh well. Random testing ID it is.
    id="test-unknown_`hexdump -v -n4 -e '"" 1/1 "%02x"' /dev/urandom`"
fi

LOCALROOT="`mktemp -d --tmpdir='/tmp' 'crouton-autotest.XXX'`"
addtrap "rm -rf --one-file-system '$LOCALROOT'"

CURTESTROOT=''
CROUTONROOT="$LOCALROOT/crouton"

LASTFILE="$LOCALROOT/last"
echo "2 `date '+%s'`" > "$LASTFILE"

READYFILE="$LOCALROOT/ready"
echo 'READY' > "$READYFILE"

readypingtime=0

while sleep "$POLLINTERVAL"; do
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
                echo "BEGIN TEST SUITE $tname"
                ret=''
                mkdir -p "$CROUTONROOT"
                if wget -qO- "$tarball" \
                        | tar -C "$CROUTONROOT" -xz --strip-components=1; then
                    ret=0
                    sh -e "$CROUTONROOT/test/run.sh" -l "$logdir" $params \
                        || ret=$?
                fi
                rm -rf --one-file-system "$CROUTONROOT"
                if [ -z "$ret" ]; then
                    result="TEST SUITE $tname FAILED: unable to download branch"
                elif [ "$ret" != 0 ]; then
                    result="TEST SUITE $tname FAILED: finished with exit code $ret"
                else
                    result="TEST SUITE $tname PASSED: finished with exit code $ret"
                fi
                echo "$result"
                (echo 'READY'; echo "$result") > "$READYFILE"
            } 2>&1 | statusmonitor

            CURTESTROOT=''
            cat "$READYFILE" | statusmonitor
        done
        echo "$lastline $last" > "$LASTFILE"
    }
    # Update the 'ready' file once every $READYPINGTIME seconds
    if [ "$readypingtime" -le 0 ]; then
        cat "$READYFILE" | statusmonitor
        readypingtime="$READYPINGINTERVAL"
    else
        readypingtime="$(($readypingtime-$POLLINTERVAL))"
    fi
done
