#!/usr/bin/env python
# Copyright (c) 2015 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Python script to call croutoncycle. This is needed to let the 
# hotkeys ctr-shift-alt F1/F2 work when xbmc is in fullscreen.
import subprocess
import sys

if len(sys.argv) == 2 and sys.argv[1] in ("prev", "next"):
  exitcode = subprocess.call(["/usr/local/bin/croutoncycle", sys.argv[1]])
else:
  sys.stderr.write("Usage: %s prev|next\n" % str(sys.argv[0]))
  exitcode = 2
sys.exit(exitcode)
