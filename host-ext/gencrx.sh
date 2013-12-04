#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# This script generates a crx extension package, and is meant to be used by
# developers: Users should download the extension from the Web Store.
#
# We could leverage on Chrome to build the extension, using something like
# /opt/google/chrome/chrome --pack-extension=crouton
# However many versions cannot build the package without crashing:
#  - 27.0.1453.116 aborts at the end of the process, but the package still
#    looks fine.
#  - 28.0.1500.95 aborts before creating the extension.
#
# This code is loosely based a script found along the CRX file format
# specification: http://developer.chrome.com/extensions/crx.html

EXTNAME="crouton"

cd "`dirname "$0"`"

rm -f "$EXTNAME.crx" "$EXTNAME.zip"

trap "rm -f '$EXTNAME.sig' '$EXTNAME.pub'" 0

# Create zip file
( cd $EXTNAME; zip -qr -9 -X "../$EXTNAME.zip" . )

if [ ! -e "$EXTNAME.pem" ]; then
    openssl genrsa -out "$EXTNAME.pem" 1024
fi

# Signature
openssl sha1 -sha1 -binary -sign "$EXTNAME.pem" <"$EXTNAME.zip" >"$EXTNAME.sig"

# Public key
openssl rsa -pubout -outform DER < "$EXTNAME.pem" >"$EXTNAME.pub" 2>/dev/null

# Print a 32-bit integer, Little-endian byte order
printint() {
    val="$1"
    i=4
    while [ $i -gt 0 ]; do
        lsb="$(($val % 256))"
        oct="`printf '%o' $lsb`"
        printf "\\$oct"
        val="$(($val / 256))"
        i="$(($i-1))"
    done
}

{
    # Magic number
    echo -n 'Cr24'
    # Version
    printint 2
    # Public key length
    printint "`stat -c'%s' "$EXTNAME.pub"`"
    # Signature length
    printint "`stat -c'%s' "$EXTNAME.sig"`"
    cat "$EXTNAME.pub" "$EXTNAME.sig" "$EXTNAME.zip"
} > "$EXTNAME.crx"
