;; Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
;; Use of this source code is governed by a BSD-style license that can be
;; found in the LICENSE file.

;; Run xbindkeys -dg for some example configuration file with explanation

; Cycle chroots
(xbindkey '(control shift alt F1) "
    for key in Control Shift Alt Meta; do
        echo 'keyup '$key'_L'
        echo 'keyup '$key'_R'
    done | xte
    croutoncycle prev")
(xbindkey '(control shift alt F2) "
    for key in Control Shift Alt Meta; do
        echo 'keyup '$key'_L'
        echo 'keyup '$key'_R'
    done | xte
    croutoncycle next")

; Extra bindings that must only be activated in chroot X11/Xephyr
(if (not (string-null? (getenv "XMETHOD")))
    (begin
        ; Brightness control
        (xbindkey '(XF86MonBrightnessDown) "brightness down")
        (xbindkey '(XF86MonBrightnessUp) "brightness up")

        ; Load ~/.xbindkeysrc.scm for customization if the current user has one
        (let ((usercfg (string-append (getenv "HOME") "/.xbindkeysrc.scm")))
            (if (access? usercfg F_OK) (load usercfg))
        )
    )
)
