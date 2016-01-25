#!/bin/sh -e
# Copyright (c) 2015 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Monitors a web-based CSV queue for autotest requests, runs the test, and
# uploads the status and results.

# Example CSV contents (must be fully quoted, no double-quotes in content):
#   "Timestamp","Repository","Branch","Additional parameters","Run type"
#   "2013/10/16 8:24:52 PM GMT","dnschneid/crouton","master","","FULL"

set -e

APPLICATION="${0##*/}"
SCRIPTDIR="`readlink -f "\`dirname "$0"\`/.."`"
# Poll queue file every x seconds
POLLINTERVAL=10
# Full sync status at least every x seconds
LOGUPLOADINTERVAL=60
# After the end of a test, try to fetch results for x seconds
FETCHTIMEOUT=1200
# Archive every hour, files older than 7 days
ARCHIVEINTERVAL=3600
ARCHIVEMAXAGE=7
# Archive status file when it gets too long
ARCHIVEMAXLINES=1000
QUEUEURL=''
RSYNCBASEOPTIONS='-aP'
RSYNCRSH='ssh'
RSYNCOPTIONS=''
# Persistent storage directory
LOCALROOT="$SCRIPTDIR/test/daemon"
UPLOADROOT="$HOME"
AUTOTESTGIT="https://chromium.googlesource.com/chromiumos/third_party/autotest"
TESTINGSSHKEYURL="https://chromium.googlesource.com/chromiumos/chromite/+/master/ssh_keys/testing_rsa"
MIRRORENV=""
# Maximum test run time (minutes): 24 hours
MAXTESTRUNTIME="$((24*60))"
GSAUTOTEST="gs://chromeos-autotest-results"

USAGE="$APPLICATION [options] -q QUEUEURL

Runs a daemon that polls a CSV on the internet for tests to run, and uploads
status and results to some destination via scp.

Options:
    -e MIRRORENV   key=value pair to pass to tests to setup default mirrors.
                   Can be specified multiple times.
    -l LOCALROOT   Local persistent log directory
    -q QUEUEURL    Queue URL to poll for new test requests. Must be specified.
    -r RSYNCOPT    Special options to pass to rsync in addition to $RSYNCBASEOPTIONS
                   Default: ${RSYNCOPTIONS:-"(nothing)"}
    -s RSYNCRSH    rsh command to use for rsync.
                   Default: $RSYNCRSH
    -u UPLOADROOT  Base rsync-compatible URL directory to upload to. Must exist.
                   Default: $UPLOADROOT"

# Common functions
. "$SCRIPTDIR/installer/functions"

# Process arguments
while getopts 'e:l:q:r:s:u:' f; do
    case "$f" in
    e) MIRRORENV="$OPTARG;$MIRRORENV";;
    l) LOCALROOT="$OPTARG";;
    q) QUEUEURL="$OPTARG";;
    r) RSYNCOPTIONS="$OPTARG";;
    s) RSYNCRSH="$OPTARG";;
    u) UPLOADROOT="$OPTARG";;
    \?) error 2 "$USAGE";;
    esac
done
shift "$((OPTIND-1))"

if [ -z "$QUEUEURL" -o "$#" != 0 ]; then
    error 2 "$USAGE"
fi

# No double-quotes in MIRRORENV
if [ "${MIRRORENV#*\"}" != "$MIRRORENV" ]; then
    error 2 "$USAGE"
fi

# Find a board name from a given host name
# Also creates a host info file, that is used by findrelease
findboard() {
    local host="$1"

    local hostinfo="$HOSTINFO/$host"
    local hostinfonew="$HOSTINFO/$host.new"

    if echo '
echo
echo "HWID=`crossystem hwid`"
cat /etc/lsb-release
' | ssh "root@${host}.cros" $DUTSSHOPTIONS > "$hostinfonew"; then
        mv "$hostinfonew" "$hostinfo"
    fi

    if [ ! -s "$hostinfo" ]; then
        echo "Cannot fetch host info, and no cache" 1>&2
        return 1
    fi

    # Drop freon suffix (Omaha will get us back to freon if needed)
    sed -n 's/[_-]freon$//;s/^CHROMEOS_RELEASE_BOARD=//p' "$hostinfo"
}

# Find a release/build name from host, board and channel
findrelease() {
    local host="$1"
    local channel="$2"
    local board="`findboard "$host"`"
    local hostinfo="$HOSTINFO/$host"

    local appidtype="RELEASE"
    if [ "$channel" = "canary" ]; then
        appidtype="CANARY"
    fi
    local appid="`sed -n "s/^CHROMEOS_${appidtype}_APPID=//p" "$hostinfo"`"
    local hwid="`sed -n 's/^HWID=//p' "$hostinfo"`"

    tee /dev/stderr<<EOF | curl -d @- https://tools.google.com/service/update2 \
            | tee /dev/stderr | awk '
        BEGIN { RS=" "; FS="=" }
        $1 == "ChromeOSVersion" {
            osver=$2; gsub(/"/, "", osver)
        }
        $1 == "ChromeVersion" {
            ver=$2; gsub(/"/, "", ver); gsub(/\..*$/, "", ver)
        }
        $2 ~ /-freon_/ { # Freon detection heuristics
            # If there is already an _ => use -, otherwise _
            if ("'$board'" ~ /_/)
                freon="-freon"
            else
                freon="_freon"
        }
        END {
            if (length(ver) > 0 && length(osver) > 0)
                print "cros-version:'$board'" freon "-release/R" ver "-" osver
        }'
<?xml version="1.0" encoding="UTF-8"?>
<request protocol="3.0" version="ChromeOSUpdateEngine-0.1.0.0"
                 updaterversion="ChromeOSUpdateEngine-0.1.0.0">
    <os version="Indy" platform="Chrome OS"></os>
    <app appid="${appid}" version="0.0.0" track="${channel}-channel"
         lang="en-US" board="${board}" hardware_class="${hwid}"
         delta_okay="false" fw_version="" ec_version="" installdate="2800" >
        <updatecheck targetversionprefix=""></updatecheck>
        <event eventtype="3" eventresult="2" previousversion=""></event>
    </app>
</request>
EOF
}

lastfullsync=0
lastarchivesync=0
forceupdate=

# Sync status directory
# Passing a parameter will sync that specific file only
syncstatus() {
    local file="$1"
    local extraoptions=""
    if [ -z "$file" ]; then
        extraoptions="--exclude archive --delete"
        local time="`date '+%s'`"

        # Auto-archive
        if [ "$((lastarchivesync+ARCHIVEINTERVAL))" -lt "$time" ]; then
            (
                cd $STATUSROOT
                mkdir -p "archive"
                find -maxdepth 1 -type d -mtime +"$ARCHIVEMAXAGE" \
                     -regex '\./[-0-9]*_[-0-9]*_.*' | while read -r dir; do
                    dest="archive/${dir##*/}.tar.bz2"
                    rm -f "$dest"
                    tar -caf "$dest" "${dir#./}"
                    rm -rf "$dir"
                done

                # Only keep ARCHIVEMAXLINES lines of status
                count="`cat status | wc -l`"
                if [ "$count" -gt "$ARCHIVEMAXLINES" ]; then
                    cut="$((count-ARCHIVEMAXLINES/2))"
                    cut1="$((cut+1))"
                    head -n "$cut" status >> archive/status
                    tail -n +"$cut1" status > status.tmp
                    mv status.tmp status
                    # TODO: We probably want to compress archive/status
                fi
            )
            syncstatus "archive/"
            forceupdate=y
            lastarchivesync="$time"
        fi

        if [ -z "$forceupdate" ]; then
            if [ "$((lastfullsync+LOGUPLOADINTERVAL))" -gt "$time" ]; then
                echo "Skipping sync (throttling)..." 1>&2
                return
            fi
        else
            forceupdate=
        fi
        lastfullsync="$time"
    fi
    echo "Syncing $file" 1>&2
    rsync $RSYNCBASEOPTIONS $RSYNCOPTIONS $extraoptions -e "$RSYNCRSH" \
            "$STATUSROOT/$file" "$UPLOADROOT/$file" >/dev/null 2>&1
    echo "Done" 1>&2
}

log() {
    timestamp="`TZ= date +"%Y-%m-%d %H:%M:%S.%N"`"
    echo "$timestamp:$@" | tee -a "$STATUSROOT/status" 1>&2
    syncstatus status
}

# Temporary files
TMPROOT="`mktemp -d --tmpdir='/tmp' 'crouton-autotest.XXX'`"
addtrap "rm -rf --one-file-system '$TMPROOT'"
LASTFILE="$TMPROOT/last"
echo "2 `date '+%s'`" > "$LASTFILE"
HOSTINFO="$TMPROOT/hostinfo"
mkdir -p "$HOSTINFO"

# Stateful files, kept between runs
mkdir -p "$LOCALROOT"

# status directory: synced via rsync
STATUSROOT="$LOCALROOT/status"
mkdir -p "$STATUSROOT"

log "crouton autotest daemon starting..."

echo "Fetching latest autotest..." 1>&2
AUTOTESTROOT="$LOCALROOT/autotest.git"
if [ -d "$AUTOTESTROOT/.git" ]; then
    git -C "$AUTOTESTROOT" fetch
    git -C "$AUTOTESTROOT" reset --hard origin/master >/dev/null
else
    rm -rf "$AUTOTESTROOT"
    git clone "$AUTOTESTGIT" "$AUTOTESTROOT"
fi
# Build external dependencies, see crbug.com/502534
(
    cd "$AUTOTESTROOT"
    ./utils/build_externals.py
)

PATH="$AUTOTESTROOT/cli:$PATH"

echo "Checking if gsutil is installed..." 1>&2
gsutil version

echo "Fetching testing ssh keys..." 1>&2
SSHKEY="$LOCALROOT/testing_rsa"
wget "$TESTINGSSHKEYURL?format=TEXT" -O- | base64 -d > "$SSHKEY"
chmod 0600 "$SSHKEY"

# ssh control directory
mkdir -p "$TMPROOT/ssh"

# ssh options for the DUTs
DUTSSHOPTIONS="-o ConnectTimeout=30 -o IdentityFile=$SSHKEY \
-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
-o ControlPath=$TMPROOT/ssh/%h \
-o ControlMaster=auto -o ControlPersist=10m"

syncstatus

while sleep "$POLLINTERVAL"; do
    read -r lastline last < "$LASTFILE"
    # Grab the queue, skip to the next interesting line, convert field
    # boundaries into pipe characters, and then parse the result.
    # Any line still containing a double-quote after parsing is ignored
    (wget -qO- "$QUEUEURL" && echo) | tail -n"+$lastline" \
            | sed 's/^"//; s/","/|/g; s/"$//; s/.*".*//' | {
        while IFS='|' read -r date repo branch params run _; do
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

            if [ "$branch" = "*RELOAD" ]; then
                log "Daemon: Reloading..."
                exit 99
            fi

            date="`date -u '+%Y-%m-%d_%H-%M-%S' --date="@$date"`"
            paramsstr="${params:+"_"}`echo "$params" | tr ' [:punct:]' '_-'`"
            tname="${date}_${gituser}_${repo}_$branch$paramsstr"
            curtestroot="$STATUSROOT/$tname"

            # By default, try all channels and match string in "run"
            channels="stable beta dev canary"

            # If run is a predefined string, set channels and match everything
            if [ "${run#SHORT}" != "$run" ]; then
                channels="default"
                run="-"
            elif [ "${run#FULL+CANARY}" != "$run" ]; then
                channels="stable beta dev canary"
                run="-"
            elif [ "${run#FULL}" != "$run" ]; then
                channels="stable beta dev"
                run="-"
            fi

            mkdir -p "$curtestroot"

            log "$tname *: Dispatching (channels=$channels)"

            hostlist="`atest host list -w cautotest \
                                       -N -b pool:crouton --unlocked || true`"
            if [ -z "$hostlist" ]; then
                log "$tname *: Failed to retrieve host list"
                continue
            fi

            for host in $hostlist; do
                if [ "$channels" = "default" ]; then
                    # Use atest labels to select which channels to run tests on
                    hostchannels="`atest host list --parse "$host" | \
                                   sed -n 's/.*|Labels=\([^|]*\).*/\1/p' | \
                                   tr ',' '\n' | sed -n 's/ *crouton://p'`"
                    if [ -z "$hostchannels" ]; then
                        log "ERROR: No default channel configured for $host."
                        continue
                    fi
                else
                    hostchannels="$channels"
                fi
                for channel in $hostchannels; do
                    # Abbreviation of host name (one letter, one number)
                    hostshort="`echo "$host" \
                                    | sed -e 's/-*\([a-z]\)[a-z]*/\1/g'`"

                    # Find board name
                    board="`findboard "$host" || true`"
                    if [ -z "$board" ]; then
                        log "$tname $hostshort: ERROR cannot find board name!"
                        continue
                    fi

                    hostfull="$hostshort-$board-$channel"

                    # Check if hostfull matches any of the run strings
                    match=
                    for r in $run; do
                        if [ "$hostfull" != "${hostfull#*$r}" ]; then
                            match=y
                            break
                        fi
                    done
                    if [ -z "$match" ]; then
                        echo "No match for $hostfull ($run)."
                        continue
                    fi

                    # Find release image
                    release="`findrelease "$host" "$channel" || true`"
                    if [ -z "$release" ]; then
                        log "$tname $hostfull: ERROR cannot find release name!"
                        continue
                    fi

                    curtesthostroot="$curtestroot/$hostfull"
                    if [ -d "$curtesthostroot" ]; then
                        log "$tname $hostfull: Already started"
                        continue
                    fi

                    mkdir -p "$curtesthostroot"

                    # Generate control file
                    sed -e "s|###REPO###|$gituser/$repo|" \
                        -e "s|###BRANCH###|$branch|" \
                        -e "s|###RUNARGS###|$params|" \
                        -e "s|###ENV###|$MIRRORENV|" \
                        $SCRIPTDIR/test/autotest_control.template \
                        > "$curtesthostroot/control"

                    echo "$host" > "$curtesthostroot/host"

                    # Run test with atest
                    ret=
                    (
                        set -x
                        atest job create -m "$host" -w cautotest \
                            -f "$curtesthostroot/control" \
                            -d "$release" \
                            -B always --max_runtime="$MAXTESTRUNTIME" \
                            "$tname-$hostfull"
                    ) > "$curtesthostroot/atest" 2>&1 || ret=$?

                    if [ -z "$ret" ]; then
                        cat "$curtesthostroot/atest" | tr '\n' ' ' | \
                            sed -e 's/^.*(id[^0-9]*\([0-9]*\)).*$/\1/' \
                            > "$curtesthostroot/jobid"
                    else
                        log "$tname $hostfull: Create job failed"
                    fi
                    forceupdate=y
                done # channel
            done # host
            syncstatus
        done
        echo "$lastline $last" > "$LASTFILE"
    }

    # Check status of running tests
    for curtestroot in "$STATUSROOT"/*; do
        if [ ! -d "$curtestroot" ]; then
            continue
        fi
        curtestupdated=
        curtest="${curtestroot#$STATUSROOT/}"
        for curtesthostroot in "$curtestroot"/*; do
            curtesthost="${curtesthostroot#$curtestroot/}"
            curtesthostresult="$curtesthostroot/results"

            # If jobid file exists, test is running, or results have not been
            # fetched yet
            if [ -f "$curtesthostroot/jobid" ]; then
                jobid="`cat "$curtesthostroot/jobid"`"
                host="`cat "$curtesthostroot/host" || true`"
                newstatusfile="$curtesthostroot/newstatus"
                statusfile="$curtesthostroot/status"
                if ! atest job list --parse "$jobid" > "$newstatusfile"; then
                    log "$curtest $curtesthost: Cannot get status."
                    continue
                fi
                status="`awk 'BEGIN {RS="|";FS="="} $1~/^Status/{print $2}' \
                             "$newstatusfile"`"
                if ! diff -q "$newstatusfile" "$statusfile" >/dev/null 2>&1; then
                    log "$curtest $curtesthost: $status"
                    curtestupdated=y
                    mv "$newstatusfile" "$statusfile"
                else
                    rm -f "$newstatusfile"
                fi

                # If status is Running, rsync from the host. Move the current
                # results dir away, then use rsync --link-dest, so that partial
                # files are used, but old files deleted
                if [ "$status" = "Running" -a -n "$host" ]; then
                    rm -rf "$curtesthostresult.old"
                    mkdir -p "$curtesthostresult"
                    mv -T "$curtesthostresult" "$curtesthostresult.old"
                    mkdir -p "$curtesthostresult"
                    for path in "status.log" "debug/" \
                        "platform_Crouton/debug/platform_Crouton." \
                        "platform_Crouton/results/"; do
                        rsync -e "ssh $DUTSSHOPTIONS" -aP \
                                         --link-dest="$curtesthostresult.old/" \
              "root@${host}.cros:/usr/local/autotest/results/default/${path}*" \
                            "$curtesthostresult/" || true
                    done
                    rm -rf "$curtesthostresult.old"
                    curtestupdated=y
                fi

                # FIXME: Any more final statuses?
                # Actually, partial Aborted tests end up as Completed
                # Not sure about Failed...
                if [ "$status" = "Aborted" -o "$status" = "Failed" \
                                           -o "$status" = "Completed" ]; then
                    # Get user name
                    user="`awk 'BEGIN{ RS="|"; FS="=" }
                                $1~/^Owner/{print $2}' "$statusfile"`"
                    # It may take a while for the files to be transfered, retry
                    # for at most FETCHTIMEOUT seconds, as, sometimes, no file
                    # ever appears (Aborted tests, for example)
                    if ! root="`gsutil ls "$GSAUTOTEST/$jobid-$user"`"; then
                        echo "Cannot fetch $jobid-$user..." 1>&2
                        time="`date '+%s'`"
                        statustimefile="$curtesthostroot/statustime"
                        if [ ! -f "$statustimefile" ]; then
                            echo $time > "$statustimefile"
                            continue
                        fi
                        statustime="`cat "$statustimefile"`"
                        if [ "$((statustime+FETCHTIMEOUT))" -gt "$time" ]; then
                            continue
                        fi
                        status2="NO_DATA"
                    else
                        # Ensure results are fully re-fetched
                        rm -rf "$curtesthostresult" "$curtesthostresult.old"
                        mkdir -p "$curtesthostresult"
                        for path in "status.log" "debug/" \
                                "platform_Crouton/debug/platform_Crouton." \
                                "platform_Crouton/results/"; do
                            # FIXME: Can we prevent partial fetches???
                            gsutil cp "${root}${path}*" "$curtesthostresult" \
                                > /dev/null 2>&1 || true
                        done
                        status2="`awk '($1 == "END") && \
                                       ($3 == "platform_Crouton") \
                                           { print $2 }' \
                                       "$curtesthostresult/status.log" || true`"
                    fi
                    log "$curtest $curtesthost: $status ${status2:="UNKNOWN"}"
                    sed -i -e "s;\$;|Status2=$status2|;" "$statusfile"
                    rm $curtesthostroot/jobid
                    curtestupdated=y
                fi
            fi
        done

        # Update summary
        (
            cd "$curtestroot"
            for dir in *; do
                if [ -f "$dir/status" ]; then
                    awk '
                        BEGIN{ RS="|"; FS="=" }
                        { data[$1] = $2 }
                        END{ print "'"$dir"'(" data["Id"] "): " \
                                   data["Status Counts"] " " \
                                   data["Status2"] }
                    ' "$dir/status"
                fi
            done > "$TMPROOT/newstatus"
            if ! diff -q "$TMPROOT/newstatus" status >/dev/null 2>&1; then
                mv "$TMPROOT/newstatus" status
                forceupdate=y
                curtestupdated=y
            else
                rm -f "$TMPROOT/newstatus"
            fi

            if [ -n "$curtestupdated" ]; then
                "$SCRIPTDIR"/test/genreport.sh > status.html
            fi
        )
    done

    # Display host status
    atest host list --parse -w cautotest -b pool:crouton \
        > "$STATUSROOT/newhoststatus"
    if ! diff -q "$STATUSROOT/newhoststatus" \
                 "$STATUSROOT/hoststatus" >/dev/null 2>&1; then
        mv "$STATUSROOT/newhoststatus" "$STATUSROOT/hoststatus"
        forceupdate=y
    else
        rm -f "$STATUSROOT/newhoststatus"
    fi
    atest host list -w cautotest -b pool:crouton \
        > "$STATUSROOT/hoststatus.txt"

    syncstatus
done
