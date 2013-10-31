#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Provides common functions and variables, then runs all of the tests in tests/

APPLICATION="${0##*/}"
SCRIPTDIR="`readlink -f "\`dirname "$0"\`/.."`"
# List of all supported (non-*'d) releases
SUPPORTED_RELEASES="`awk '/[^*]$/ { printf $1 " " }' \
                         "$SCRIPTDIR/installer/"*"/releases"`"
SUPPORTED_RELEASES="${SUPPORTED_RELEASES%" "}"
# System info
SYSTEM="`awk -F= '/_RELEASE_DESCRIPTION=/ {print $2}' /etc/lsb-release`"
TESTDIR="$SCRIPTDIR/test/run"
TESTNAME="`sh -e "$SCRIPTDIR/build/genversion.sh" test`"
TESTDIR="$TESTDIR/$TESTNAME"
# PREFIX intentionally includes a space. Run in /usr/local to avoid encryption
PREFIXROOT="/usr/local/$TESTNAME prefix"
# Choose a random release as the test release when the release (shouldn't) matter
RELEASE="`echo "$SUPPORTED_RELEASES" | tr ' ' "\n" | sort -R | head -n 1`"

JOBS="`grep -c '^processor' /proc/cpuinfo`"

USAGE="$APPLICATION [options] [test [...]]

Runs tests of the crouton infrastructure. Omitting specific tests will run all
of them in sequence. Alternatively, you can specify one or more test name
prefixes that are matched against the test names and run.

Tests are run out of a unique subdirectory in /usr/local, and the results are
stored in a unique subdirectory of $SCRIPTDIR/test/run

Options:
    -j JOBS      Number of tests to run in parallel. Default: $JOBS
    -l LOGDIR    Put test logs in the specified directory.
                 Default: $TESTDIR
    -r RELEASE   Specify a release to use whenever it shouldn't matter.
                 Default is a random supported release, such as $RELEASE.
    -R RELEASES  Limit the 'all supported releases' testing to a comma-separated
                 list of releases. Default: all supported releases are tested."

# Common functions
. "$SCRIPTDIR/installer/functions"

# Process arguments
while getopts 'j:l:r:R:' f; do
    case "$f" in
    j) JOBS="$OPTARG";;
    l) TESTDIR="${OPTARG%/}";;
    r) RELEASE="$OPTARG";;
    R) SUPPORTED_RELEASES="`echo "$OPTARG" | tr ',' ' '`";;
    \?) error 2 "$USAGE";;
    esac
done
shift "$((OPTIND-1))"

# We need to run as root
if [ ! "$USER" = root -a ! "$UID" = 0 ]; then
    error 2 "${0##*/} must be run as root."
fi

echo "Running tests in $PREFIXROOT" 1>&2
echo "Logging to $TESTDIR" 1>&2
echo "System: $SYSTEM" 1>&2
echo "Supported releases: $SUPPORTED_RELEASES" 1>&2
echo "Default release for this run: $RELEASE" 1>&2

# Logs all output to the specified file with the date and time prefixed.
# File is always appended.
# $1: log file or directory
# $2+: command to log
log() {
    local file="$1" line='{print strftime("%F %T: ") $0}'
    shift
    if [ -d "$file" ]; then
        file="$file/log"
    fi
    echo "`date '+%F %T:'` Launching '$*'" | tee -a "$file" 1>&2
    local start="`date '+%s'`"
    local retpreamble="'$*' finished with exit code"
    # srand() uses system time as seed but returns previous seed. Call it twice.
    ((ret=0; "$@" < /dev/null || ret=$?; sleep 1; echo "$retpreamble $ret") \
            | mawk -W interactive '
                        {srand(); print (srand()-'"$start"') " [i] " $0}
            ') 2>&1 | mawk -W interactive '
                        ($2 == "[i]") {print; next}
                        {srand(); print (srand()-'"$start"') " [e] " $0}
            ' >> "$file"
    # Output the return and relay success
    tail -n1 "$file" | tee /dev/stderr | grep -q "$retpreamble 0\$"
}

# Tests and outputs success or failure. Parameters are the same as "test".
# Returns 1 on failure
test() {
    if [ "$@" ]; then
        echo "SUCCESS: [ $* ]" 1>&2
        return 0
    else
        echo "FAILED: [ $* ]" 1>&2
        return 1
    fi
}

# Returns a temporary file in the prefix, so you don't have to clean it up
# $1 (optional): specify a prefix
tmpfile() {
    mktemp --tmpdir="$PREFIX" "${1:-tmp}.XXXXXX"
}

# Launches the installer with the specified parameters; auto-includes -p
# If -T is the first parameter, passes stdin into /prepare.sh
crouton() {
    local ret='0' tfile=''
    if [ "$1" = '-T' ]; then
        shift
        tfile="`mktemp --tmpdir="$PREFIX" target.XXXXXX`"
        {
            echo 'REQUIRES="core"
. "${TARGETSDIR:="$PWD"}/common"
### Append to prepare.sh:'
            cat
        } > "$tfile"
    fi
    echo "LAUNCHING: crouton${tfile:+" -T "}$tfile $*" 1>&2
    if [ -n "$tfile" ]; then
        echo "BEGIN $tfile CONTENTS" 1>&2
        cat "$tfile" 1>&2
        echo "END $tfile CONTENTS" 1>&2
        sh -e "$SCRIPTDIR/installer/main.sh" -T "$tfile" -p "$PREFIX" "$@" \
            || ret="$?"
    else
        sh -e "$SCRIPTDIR/installer/main.sh" -p "$PREFIX" "$@" || ret="$?"
    fi
    if [ -n "$tfile" ]; then
        rm -f "$tfile"
    fi
    if [ "$ret" != 0 ]; then
        echo "FAILED with code $ret: crouton $*" 1>&2
    fi
    return "$ret"
}

# Downloads a bootstrap if not done already and returns the tarball.
# Safe to run in parallel.
# $1: the release to bootstrap
# returns the path on stdout.
bootstrap() {
    local file="$PREFIXROOT/$1-bootstrap.tar.gz"
    echo "$file"
    if [ ! -s "$file" ]; then
        # Use flock so that bootstrap can ba called in parallel
        if flock -n 3 && [ ! -s "$file" ]; then
            crouton -r "$1" -f "$file" -d 1>&2
        else
            echo "Waiting for bootstrap for $1 to complete..." 1>&2
            flock 3
        fi 3>"$file"
        if [ ! -s "$file" ]; then
            echo "FAILED due to incomplete bootstrap for $1" 1>&2
            return 1
        fi
    fi
}

# Downloads and installs a basic chroot with the specified targets, then backs
# it up for quicker test starts. Safe to run in parallel; takes advantage of
# bootstraps as well.
# $1: the release to install
# $2: comma-separated list of targets. defaults to 'core'
# $3: name of the chroot to extract to; default is the release name
snapshot() {
    local targets="${2:-core}"
    local file="$PREFIXROOT/$1-$targets-snapshot.tar.gz"
    local name="${3:-"$1"}"
    if [ ! -s "$file" ]; then
        # Use flock so that snapshot can ba called in parallel
        if flock -n 3 && [ ! -s "$file" ]; then
            crouton -f "`bootstrap "$1"`" -t "$targets" -n "$name" 1>&2
            host edit-chroot -y -b -f "$file" "$name"
            return 0
        else
            echo "Waiting for snapshot for $1-$targets to complete..." 1>&2
            flock 3
        fi 3>"$file"
    fi
    # Restore the snapshot into place
    crouton -f "$file" -n "$name"
}

# Runs a host command with the specified parameters
# $1 command to run (enter-chroot, etc)
# $2+ parameters
host() {
    local cmd="$1" ret='0'
    shift
    echo "LAUNCHING: $cmd $*" 1>&2
    sh -e "$PREFIX/bin/$cmd" "$@" || ret="$?"
    if [ "$ret" = 0 ]; then
        echo "SUCCESS: $cmd $*" 1>&2
    else
        echo "FAILED with code $ret: $cmd $*" 1>&2
    fi
    return "$ret"
}

# Returns success if command exits with code X within Y seconds
# If the command takes longer than Y seconds, kills it with SIGTERM
# $1 exit code to expect
# $2 number of seconds within which the command should exit
# $3+ command to run
exitswithin() {
    local code="$1" seconds="$2" ret=0
    shift 2
    echo "Expecting '$*' to exit with code $code within $seconds seconds" 1>&2
    "$@" &
    local pid="$!"
    (sleep "$seconds" && exec kill -TERM "$pid") &
    local sleepid="$!"
    wait "$pid" || ret="$?"
    sleep .1
    if kill "$sleepid" 2>/dev/null; then
        if [ "$ret" = "$code" ]; then
            echo "SUCCESS: '$*' exited with code $ret within $seconds seconds" 1>&2
        else
            echo "FAILED: '$*' exited with code $ret instead of $code" 1>&2
            return 1
        fi
    else
        echo "FAILED: '$*' took more than $seconds seconds to exit" 1>&2
        return 2
    fi
    return 0
}

# Returns success if command runs longer than X seconds; exit code is ignored
# If the command survives longer than X seconds, kills it with SIGINT
# $1 number of seconds the command should survive
# $2+ command to run
runslongerthan() {
    local seconds="$1" ret=0
    shift
    echo "Expecting '$*' to survive longer than $seconds seconds" 1>&2
    "$@" &
    local pid="$!"
    (sleep "$seconds" && exec kill -INT "$pid") &
    local sleepid="$!"
    wait "$pid" || ret="$?"
    sleep .1
    if kill "$sleepid" 2>/dev/null; then
        echo "FAILED: '$*' did not survive at least $seconds seconds (returned $ret)" 1>&2
        return 2
    else
        echo "SUCCESS: '$*' survived for $seconds seconds (returned $ret)" 1>&2
    fi
    return 0
}

# Expects a successful return code from the provided command.
passes() {
    echo "Expecting '$*' to succeed" 1>&2
    local ret=0
    "$@" || ret=$?
    if [ "$ret" = 0 ]; then
        echo "SUCCESS: '$*' succeeded" 1>&2
    else
        echo "FAILED: '$*' returned $ret" 1>&2
        return "$ret"
    fi
    return 0
}

# Expects a failure return code from the provided command.
fails() {
    echo "Expecting '$*' to fail" 1>&2
    local ret=0
    "$@" || ret=$?
    if [ "$ret" != 0 ]; then
        echo "SUCCESS: '$*' returned $ret" 1>&2
    else
        echo "FAILED: '$*' succeeded" 1>&2
        return 1
    fi
    return 0
}

# Default responses to questions
export CROUTON_USERNAME='test'
export CROUTON_PASSPHRASE='hunter2'
export CROUTON_NEW_PASSPHRASE="$CROUTON_PASSPHRASE"
export CROUTON_EDIT_RESPONSE='y'
export CROUTON_MOUNT_RESPONSE='y'
export CROUTON_UNMOUNT_RESPONSE='y'

# Prevent powerd from sleeping the system
sh -e "$SCRIPTDIR/chroot-bin/croutonpowerd" -i &
croutonpowerd="$!"

# Run all the tests
mkdir -p "$TESTDIR" "$PREFIXROOT"
addtrap "echo 'Cleaning up...' 1>&2
    set +e
    pkill debootstrap 2>/dev/null
    kill \$jobpids 2>/dev/null
    for pid in \$jobpids; do
        wait \$pid 2>/dev/null
    done
    for m in '$PREFIXROOT/'*; do
        if [ -d \"\$m/chroots\" ]; then
            sh -e '$SCRIPTDIR/host-bin/unmount-chroot' -a -y -c \"\$m/chroots\"
        fi
        if mountpoint -q \"\$m\"; then
            umount -l \"\$m\" 2>/dev/null
        fi
    done
    rm -rf --one-file-system '$PREFIXROOT'
    kill '$croutonpowerd' 2>/dev/null"

# If no arguments were passed, match all tests
if [ "$#" = 0 ]; then
    set -- ''
fi

jobpids=''

# Waits for there to be fewer than $1 jobs running. Reads and updates $jobpids.
# Fails if one of the jobs failed.
# If $1 is omitted, uses $JOBS
# If 0 is specified, assumes 1
waitjobs() {
    local j=0
    while [ -n "$jobpids" -a "$j" -le 0 ]; do
        j="${1:-"$JOBS"}"
        if [ "$j" -lt 1 ]; then
            j=1
        fi
        local newjobpids='' pid
        for pid in $jobpids; do
            if kill -0 "$pid" 2>/dev/null; then
                j="$((j-1))"
                newjobpids="$newjobpids $pid"
            else
                # Grab the return code
                wait "$pid"
            fi
        done
        jobpids="${newjobpids# }"
        sleep 1
    done
}

# Run all tests matching the supplied prefixes
tname=''
for p in "$@"; do
    for t in "$SCRIPTDIR/test/tests/$p"*; do
        if [ ! -s "$t" ]; then
            continue
        fi
        waitjobs
        tname="${t##*/}"
        TESTLOG="$TESTDIR/$tname"
        # Run the test
        (
            PREFIX="`mktemp -d --tmpdir="$PREFIXROOT" "$tname.XXX"`"
            # Remount PREFIX noexec/etc to make the environment as harsh as possible
            mount --bind "$PREFIX" "$PREFIX"
            mount -i -o remount,nosuid,nodev,noexec "$PREFIX"
            # Clean up on exit
            settrap "
                umount -l '$PREFIX'
                rm -rf --one-file-system '$PREFIX'
            "
            log "$TESTLOG" . "$t"
        ) &
        jobpids="$jobpids${jobpids:+" "}$!"
    done
done

# Wait for all jobs to finish
waitjobs 0

if [ -n "$tname" ]; then
    echo "All tests passed!" 1>&2
else
    echo "No tests found matching $*" 1>&2
    exit 2
fi
