#!/usr/bin/awk -f
# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Scripts that are passed over SSH have to be carefully escaped, so for
# simplicity in this project, they can't safely contain single-quotes.
# This script is used by the Makefile to check for single-quotes in files and
# spit out any errors in a standard format. 

/'/ {
    e=1;
    print FILENAME ":" FNR ":" index($$0, "'") ": error: single-quote"
}
END {
    exit e
}
