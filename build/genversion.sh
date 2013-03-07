#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Outputs a version string with the specified prefix.

if [ ! "$#" = 1 ]; then
    echo "Usage: ${0##*/} VERSION" 1>&2
    exit 1
fi

source=''

# Get the branch from git
githead="`dirname "$0"`/../.git/HEAD"
if [ -f "$githead" ]; then
    source="`cut -d/ -f3 "$githead"`"
    source="${source:+"~"}$source"
fi

VERSION="$1-%Y%m%d%H%M%S$source"

exec date "+$VERSION"
