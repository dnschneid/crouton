#!/bin/sh -e
# Copyright (c) 2014 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# This is a "server-side" test for mkpart.sh. It requires a DUT with a testing
# image installed.
#
# If run without parameter, it tries to lock all ready pool:crouton machines
# from autotest, and run tests on them. In that case, cli/ directory from
# autotest checkout must be in path:
# export PATH=.../crouton-testing/daemon/autotest.git/cli:$PATH

set -e

# Modify this as needed
REPO="drinkcat/chroagh"
BRANCH="separate_partition"

APPLICATION="${0##*/}"
SCRIPTDIR="`readlink -f "\`dirname "$0"\`/.."`"
TESTDIR="$SCRIPTDIR/test/run"
TESTNAME="`sh -e "$SCRIPTDIR/build/genversion.sh" test`"
TESTDIR="$TESTDIR/$TESTNAME"
URL="https://github.com/$REPO/archive/$BRANCH.tar.gz"
SSHOPTS="-o IdentityFile=~/.ssh/testing_rsa -o StrictHostKeyChecking=no \
-o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

# Common functions
. "$SCRIPTDIR/installer/functions"

if [ -z "$1" ]; then
    hosts="`atest host list -b pool:crouton -s Ready -N --unlocked`"
    addtrap "atest host mod --unlock $hosts"
    atest host mod --lock $hosts

    mkdir -p "$TESTDIR"
    echo "Logging to $TESTDIR"

    for host in $hosts; do
        (
            echo "Starting test on $host..." 1>&3
            if "$0" "$host.cros"; then
                echo "test on $host succeeded..." 1>&3
            else
                echo "test on $host failed..." 1>&3
            fi
        ) 3>&1 > "$TESTDIR/$host.log" 2>&1 &
    done

    wait

    exit 0
fi

HOST="$1"

ssh_run() {
    ssh $SSHOPTS root@"$HOST" "sh -exc '$1'"
}

fetch_crouton() {
    ssh_run "
        mkdir -p /tmp/mkpart
        cd /tmp/mkpart
        rm -f '$BRANCH.tar.gz'
        wget '$URL'
        tar xf '$BRANCH.tar.gz' --strip-components 1"
}

# wait_host on|off [timeout]
# Waits for host to appear/disappear
wait_host() {
    local on="${1:-on}"
    local timeout="${2:-300}"
    echo "Waiting for host to turn $on..."
    while [ "$timeout" -gt 0 ]; do
        if [ "$on" = "on" ]; then
            if ssh_run true >/dev/null 2>&1; then
                break
            fi
        else
            if ! ssh_run true >/dev/null 2>&1; then
                break
            fi
            sleep 5
        fi
        timeout="$((timeout-5))"
    done
    if [ "$timeout" -le 0 ]; then
        echo "Timeout..."
        exit 1
    fi
}

check_no_crouton_partition() {
    ssh_run '
        root="`rootdev -d -s`"
        cgpt show -i 13 "$root"
        [ "`cgpt show -i 13 -b "$root"`" = 0 ] # begin
        [ "`cgpt show -i 13 -s "$root"`" = 0 ] # size
    '
}

wait_host on 30
fetch_crouton

# Switch on the screen
ssh_run "dbus-send --system --dest=org.chromium.PowerManager \
                   --type=method_call /org/chromium/PowerManager \
                   org.chromium.PowerManager.HandleUserActivity"

exists=
echo "Checking crouton partition does not exist..."
if check_no_crouton_partition; then
    echo "Creating crouton partition..."
    ssh_run '
        cd /tmp/mkpart
        CROUTON_MKPART_YES=yes sh installer/main.sh -S -c 5000 </dev/null
    ' &
    sshpid="$!"
    wait_host off 120
    kill "$sshpid"
    wait_host on 300
    fetch_crouton
else
    echo "ERROR: Partition 13 exists already, deleting it..."
    exists=y
fi

# FIXME: We could do more precise begin/size checks
echo "Checking new partition size..."
ssh_run '
    root="`rootdev -d -s`"
    cgpt show -i 13 "$root"
    [ "`cgpt show -i 13 -b "$root"`" -gt 0 ] # begin
    [ "`cgpt show -i 13 -s "$root"`" -gt 0 ] # size
'

# Restore host-bin (this mounts the partition), then check partition is mounted
ssh_run '
    echo "Restoring host-bin..."
    sh /tmp/mkpart/installer/main.sh -b
    echo "Checking if the partition was mounted..."
    cat /proc/mounts | grep "[^ ]* /var/crouton ext4"
'

echo "Deleting partition..."
ssh_run '
    cd /tmp/mkpart
    CROUTON_MKPART_DELETE=delete sh installer/main.sh -S -d </dev/null
' &
sshpid="$!"
wait_host off 120
kill "$sshpid"
wait_host on 300

echo "Checking crouton partition does not exist..."
check_no_crouton_partition

if [ -n "$exists" ]; then
    echo "\
WARNING: Partition 13 was already present at the beginning of the test.
It was deleted successfully, but the test should be run again."
    exit 1
fi

echo "Test completed!"
exit 0
