#!/bin/sh -e
# Copyright (c) 2015 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -e

# Generates a release in the releases/ directory (which should be a checkout of
# the releases branch of the same repo) and pushes it.

USAGE="Usage: ${0##*/} [-f] bundle [..]
    -f  Hard-reset the releases branch in case of unpushed releases."
FORCE=''

# CD into the repo's root directory
dir="`readlink -f "$0"`"
cd "${dir%/*}/.."

# Import common functions
. installer/functions 

if [ "$1" = '-f' ]; then
    FORCE=y
    shift
fi

if [ "$#" = 0 ]; then
    error 2 "$USAGE"
fi

# Check the releases directory and update, or create it if necessary
if [ -d releases/.git ]; then
    if ! grep -q 'releases$' releases/.git/HEAD; then
        error 1 'releases/ is not in the releases branch.'
    fi
    if ! awk "/'releases'/{print \$1}" releases/.git/FETCH_HEAD | \
            diff -q releases/.git/refs/heads/releases - >/dev/null; then
        echo 'releases/ is ahead of or not up-to-date with remote' 1>&2
        if [ -z "$FORCE" ]; then
            exit 1
        fi
    fi
    git -C releases fetch origin releases
    git -C releases reset --hard origin/releases
elif [ -e releases ]; then
    error 1 "releases/ is not a git repo"
else
    url="`git remote -v | awk '$1=="origin" && $3=="(fetch)" {print $2}'`"
    git clone --single-branch --branch releases --reference . "$url" releases
fi

# Apply the releases
for bundle in "$@"; do
    bundle="${bundle##*/}"
    if [ ! -f "$bundle" ]; then
        error 1 "$bundle bundle does not exist"
    fi
    version="`sh "$bundle" -V`"
    if [ "$version" = "${version#crouton*:}" ]; then
        error 1 "$bundle bundle is invalid"
    fi
    branch="${version#*~}"
    branch="${branch%:*}"
    dest="${branch#master}"
    dest="crouton${dest:+-}$dest"
    # Compare the current release to avoid duplicates
    if [ -f "releases/$dest" ] && \
            sh "releases/$dest" -V | grep -q "${version#*~}"; then
        echo "Release already current: `sh "$bundle" -V`"
        continue
    fi
    # Copy it in and make a commit
    cp -fv "$bundle" "releases/$dest"
    git -C releases add "$dest"
    git -C releases commit -m "$version"
done

# Push the resulting releases
git -C releases push origin releases
git -C releases fetch origin releases

exit 0
