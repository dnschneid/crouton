/* Copyright (c) 2016 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */
'use strict';

document.addEventListener('DOMContentLoaded', function() {
    /* Update "help" link */
    var helplink = document.getElementById("help");
    helplink.onclick = showHelp;

    // Refresh the rest of the UI
    chrome.runtime.sendMessage({msg: 'refreshUI'});
});

function showHelp() {
    chrome.runtime.sendMessage({msg: 'showHelp'});
}

function updateUI(enabled, debug) {
    if (document.readyState == "loading") {
        console.log("Document still loading")
        return
    }
    /* Update enable/disable link. */
    var enablelink = document.getElementById("enable");
    if (enabled) {
        enablelink.textContent = "Disable";
        enablelink.onclick = function() {
            chrome.runtime.sendMessage({msg: 'Disable'});
        }
    } else {
        enablelink.textContent = "Enable";
        enablelink.onclick = function() {
            chrome.runtime.sendMessage({msg: 'Enable'});
        }
    }
    /* Update debug mode according to checkbox state. */
    var debugcheck = document.getElementById("debugcheck");
    debugcheck.onclick = function() {
        chrome.runtime.sendMessage({msg: 'Debug', data: debugcheck.checked});
    }
    debugcheck.checked = debug;
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    console.log("POPUP rcv message " + message.msg)
    if (message.msg == "updateUI") {
        updateUI(message.data.enabled, message.data.debug)
    }
});