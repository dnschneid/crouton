#!/bin/sh -e
# Copyright (c) 2015 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Outputs a version string with the specified prefix.

if [ ! "$#" = 1 ]; then
    echo "Usage: ${0##*/} VERSION" 1>&2
    exit 1
fi

source=''

# Get the branch from git
git="`dirname "$0"`/../.git"
if [ -f "$git/HEAD" ]; then
    source="`cut -d/ -f3 "$git/HEAD"`"
    if [ -n "$source" ]; then
        if [ -f "$git/refs/heads/$source" ]; then
            source="$source:`head -c 8 "$git/refs/heads/$source"`"
        else
            source="${source%"${source#????????}"}"
        fi
        source="~$source"
    fi
fi

VERSION="$1-%Y%m%d%H%M%S$source"

exec date "+$VERSION"
