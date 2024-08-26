/* Copyright (c) 2016 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */
'use strict';

document.addEventListener('DOMContentLoaded', function() {
    /* Update "help" link */
    var helplink = document.getElementById("help");
    helplink.onclick = showHelp;
    //FIXME: figure out how to send message to service worker
    console.log("FIXME")
    //chrome.extension.getBackgroundPage().refreshUI();
});

function showHelp() {
    chrome.runtime.sendMessage({msg: 'showHelp'});
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    console.log("POPUP rcv message " + message)
});