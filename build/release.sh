#!/bin/sh -e
# Copyright (c) 2016 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -e

# Generates a release in the releases/ directory (which should be a checkout of
# the releases branch of the same repo) and pushes it.

USAGE="Usage: ${0##*/} [-f] bundle [...]
    -f  Hard-reset the releases branch in case of unpushed releases."
FORCE=''

# Resolve the absolute path of the script and move to the repo's root directory
dir="$(readlink -f "$0")"
cd "${dir%/*}/.."

# Import common functions
. installer/functions

# Handle the `-f` flag for forced resets
if [ "$1" = '-f' ]; then
    FORCE=y
    shift
fi

# Display usage if no arguments are passed
if [ "$#" -eq 0 ]; then
    error 2 "$USAGE"
fi

# Check and prepare the `releases` directory
if [ -d releases/.git ]; then
    # Verify the releases branch
    if ! grep -q 'releases$' releases/.git/HEAD; then
        error 1 'releases/ is not in the releases branch.'
    fi
    # Check for out-of-date state
    if ! awk "/'releases'/{print \$1}" releases/.git/FETCH_HEAD | \
            diff -q releases/.git/refs/heads/releases - >/dev/null; then
        echo 'releases/ is ahead of or not up-to-date with remote' >&2
        if [ -z "$FORCE" ]; then
            exit 1
        fi
    fi
    git -C releases fetch origin releases
    git -C releases reset --hard origin/releases
elif [ -e releases ]; then
    error 1 "releases/ is not a git repository."
else
    # Clone the releases branch if it doesn't exist locally
    url="$(git remote -v | awk '$1=="origin" && $3=="(fetch)" {print $2}')"
    git clone --single-branch --branch releases --reference . "$url" releases
fi

# Process each bundle
for bundle in "$@"; do
    bundle="$(readlink -f "$bundle")"  # Resolve absolute path for the bundle
    if [ ! -f "$bundle" ]; then
        error 1 "$bundle bundle does not exist."
    fi
    version="$(sh "$bundle" -V)"
    if [ "$version" = "${version#crouton*:}" ]; then
        error 1 "$bundle bundle is invalid."
    fi
    branch="${version#*~}"
    branch="${branch%:*}"
    dest="${branch#master}"
    dest="crouton${dest:+-}$dest"

    # Avoid duplicate releases
    if [ -f "releases/$dest" ] && \
            sh "releases/$dest" -V | grep -q "${version#*~}"; then
        echo "Release already current: $(sh "$bundle" -V)"
        continue
    fi

    # Copy the bundle and create a commit
    cp -fv "$bundle" "releases/$dest"
    git -C releases add "$dest"
    git -C releases commit -m "$version"
done

# Push the updates to the releases branch
git -C releases push origin releases
git -C releases fetch origin releases

exit 0
