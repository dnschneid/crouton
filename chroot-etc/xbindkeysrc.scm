;; Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
;; Use of this source code is governed by a BSD-style license that can be
;; found in the LICENSE file.

;; Run xbindkeys -dg for some example configuration file with explanation

; Xephyr-specific bindings
(if (equal? (getenv "METHOD") "xephyr")
    (begin
        ; Replicates ratpoison shortcuts inside of Xephyr for when Xephyr
        ; grabs all keys
        (xbindkey '(control shift alt F1)
            "xte 'keyup F1'; host-x11 ratpoison -c prev")
        (xbindkey '(control shift alt F2)
            "xte 'keyup F2'; host-x11 ratpoison -c next")
        (xbindkey '(control shift alt Escape)
            "xte 'keyup Escape'; host-x11 ratpoison -c 'readkey root'")
    )
)

; X11-specific bindings
(if (equal? (getenv "METHOD") "x11")
    (begin
        ; Creates the shortcuts to cycle X11 chroots like with Xephyr
        (xbindkey '(control shift alt F1) "croutoncycle prev")
        (xbindkey '(control shift alt F2) "croutoncycle next")
    )
)

; Extra bindings that must only be activated in chroot X11/Xephyr
(if (not (equal? (getenv "CROUTON") "XINIT"))
    (begin
        ; Brightness control
        (xbindkey '(XF86MonBrightnessDown) "brightness down")
        (xbindkey '(XF86MonBrightnessUp) "brightness up")

        (let ((usercfg (string-append (getenv "HOME") "/.xbindkeysrc.scm")))
            (if (access? usercfg F_OK) (load usercfg))
        )
    )
)
