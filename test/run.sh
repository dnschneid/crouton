#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Provides common functions and variables, then runs all of the tests in tests/

SCRIPTDIR="`readlink -f "\`dirname "$0"\`/.."`"
TESTDIR="$SCRIPTDIR/test/run"
TESTDIR="$TESTDIR/`sh -e "$SCRIPTDIR/build/genversion.sh" test`"
# PREFIX intentionally includes a space
PREFIX="$TESTDIR/crouton prefix"

# Common functions
. "$SCRIPTDIR/installer/functions"

echo "Running tests in $TESTDIR"

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
    # srand() retuns system time
    ((ret=0; "$@" < /dev/null || ret=$?; sleep 1; echo "$retpreamble $ret") \
            | mawk -W interactive '
                        {print (srand()-'"$start"') " [i] " $0}
            ') 2>&1 | mawk -W interactive '
                        ($2 == "[i]") {print; next}
                        {print (srand()-'"$start"') " [e] " $0}
            ' >> "$file"
    # Output the return and relay success
    tail -n1 "$file" | tee /dev/stderr | grep -q "$retpreamble 0\$"
}

# Tests and outputs success or failure. Parameters are the same as "test".
# Returns 1 on failure
test() {
    if [ "$@" ]; then
        echo "SUCCESS: [ $* ]"
        return 0
    else
        echo "FAILED: [ $* ]" 1>&2
        return 1
    fi
}

# Launches the installer with the specified parameters
crouton() {
    local ret='0'
    echo "LAUNCHING: crouton $*"
    sh -e "$SCRIPTDIR/installer/main.sh" "$@" || ret="$?"
    if [ "$ret" != 0 ]; then
        echo "FAILED with code $ret: crouton $*" 1>&2
    fi
    return "$ret"
}

# Downloads a bootstrap if not done already and returns the tarball
# $1: the release to bootstrap
# returns the path on stdout.
bootstrap() {
    local file="$PREFIX/$1-bootstrap.tar.gz"
    echo "$file"
    if [ ! -s "$file" ]; then
        crouton -r "$1" -f "$file" -d 1>&2
    fi
}

# Runs a host command with the specified parameters
# $1 command to run (enter-chroot, etc)
# $2+ parameters
host() {
    local cmd="$1" ret='0'
    shift
    echo "LAUNCHING: $cmd $*"
    sh -e "$PREFIX/bin/$cmd" "$@" || ret="$?"
    if [ "$ret" = 0 ]; then
        echo "SUCCESS: $cmd $*"
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
    echo "Expecting '$*' to exit with code $code within $seconds seconds"
    "$@" &
    local pid="$!"
    (sleep "$seconds" && kill -TERM "$pid") &
    local sleepid="$!"
    wait "$pid" || ret="$?"
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
    echo "Expecting '$*' to survive longer than $seconds seconds"
    "$@" &
    local pid="$!"
    (sleep "$seconds" && kill -INT "$pid") &
    local sleepid="$!"
    wait "$pid" || ret="$?"
    if kill "$sleepid" 2>/dev/null; then
        echo "FAILED: '$*' did not survive at least $seconds seconds" 1>&2
        return 2
    else
        echo "SUCCESS: '$*' survived for $seconds seconds (returned $ret)" 1>&2
    fi
    return 0
}

# Prepare a variable with all of the supported releases
SUPPORTED_RELEASES="`awk '/[^*]$/ { printf $1 " " }' \
                         "$SCRIPTDIR/installer/"*"/releases"`"

# Run all the tests
mkdir -p "$PREFIX"
addtrap "echo 'Cleaning up...' 1>&2; rm -rf --one-file-system '$PREFIX' || true"

for t in "$TESTDIR/tests"/*; do
    if [ ! -s "$t" ]; then
        continue
    fi
    tname="${t##*/}"
    tlog="$TESTDIR/$tname"
    log "$TESTDIR/$tname" . "$t"
done

echo "All tests passed!" 1>&2
