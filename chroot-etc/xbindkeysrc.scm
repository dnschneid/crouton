;; Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
;; Use of this source code is governed by a BSD-style license that can be
;; found in the LICENSE file.

;; Run xbindkeys -dg for some example configuration file with explanation

; Xephyr-specific bindings
(if (equal? (getenv "METHOD") "xephyr")
    (begin
        ; Replicates ratpoison shortcuts inside of Xephyr for when Xephyr grabs all keys
        (xbindkey '(control shift alt F1) "xte 'keyup F1'; host-x11 ratpoison -c prev")
        (xbindkey '(control shift alt F2) "xte 'keyup F2'; host-x11 ratpoison -c next")
        (xbindkey '(control shift alt Escape) "xte 'keyup Escape'; host-x11 ratpoison -c 'readkey root'")
    )
)

; X11-specific bindings
(if (equal? (getenv "METHOD") "x11")
    (begin
        ; Creates the shortcuts to cycle X11 chroots like with Xephyr
        (xbindkey '(control shift alt F1) "/usr/local/bin/croutoncycle prev")
        (xbindkey '(control shift alt F2) "/usr/local/bin/croutoncycle prev")
    )
)

; Extra bindings that must only be activated in chroot X11/Xephyr
(if (not (equal? (getenv "CROUTON") "XINIT"))
    (begin
        ; Brightness control
        (xbindkey '(XF86MonBrightnessDown) "brightness down")
        (xbindkey '(XF86MonBrightnessUp) "brightness up")

        ; Map Alt+click to middle button
        ; Map on Release so that it does not appear both buttons are pressed
        (xbindkey '(release alt "b:1") "xdotool click --clearmodifiers 2")
    )
)
