/* Copyright (c) 2024 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */
'use strict';

var clipboardholder_; /* textarea used to hold clipboard content */

document.addEventListener('DOMContentLoaded', function() {
    clipboardholder_ = document.getElementById("clipboardholder");

    // Tell the service worker to start working
    chrome.runtime.sendMessage({msg: 'offscreenReady'});
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    console.log("CLIPBOARD rcv message " + message.msg)
    if (message.msg == "readClipboard") {
        clipboardholder_.value = "";
        clipboardholder_.select();
        document.execCommand("Paste");
        sendResponse(clipboardholder_.value);
    } else if (message.msg == "writeClipboard") {
        clipboardholder_.value = message.data;
        clipboardholder_.select();
        document.execCommand("Copy");
    }
});
