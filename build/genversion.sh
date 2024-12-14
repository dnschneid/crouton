 #!/bin/sh -e
# Copyright (c) 2016 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Outputs a version string with the specified prefix.

if [ "$#" -ne 1 ]; then
    echo "Usage: ${0##*/} VERSION" >&2
    exit 1
fi

VERSION_PREFIX="$1"
GIT_DIR="$(dirname "$0")/../.git"
SOURCE=""

# Get the branch from git
if [ -f "$GIT_DIR/HEAD" ]; then
    BRANCH_NAME=$(cut -d/ -f3 "$GIT_DIR/HEAD")
    if [ -n "$BRANCH_NAME" ]; then
        if [ -f "$GIT_DIR/refs/heads/$BRANCH_NAME" ]; then
            COMMIT_HASH=$(head -c 8 "$GIT_DIR/refs/heads/$BRANCH_NAME")
            SOURCE="~$BRANCH_NAME:$COMMIT_HASH"
        else
            SOURCE="~${BRANCH_NAME%"${BRANCH_NAME#????????}"}"
        fi
    fi
fi

VERSION="$VERSION_PREFIX-%Y%m%d%H%M%S$SOURCE"

exec date "+$VERSION"
