#!/usr/bin/env python
# Copyright (c) 2014 The crouton Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Python script to call croutoncycle. This is needed to let the 
# hotkeys ctr-shift-alt F1/F2 work when xbmc is in fullscreen.
import os
import sys
try:
  arg = str(sys.argv[1])
except:
  arg = ""
if arg in ("prev", "next"):
  os.system("/usr/local/bin/croutoncycle %s" % arg)
else:
  print ("Usage: %s prev|next" % str(sys.argv[0]))
