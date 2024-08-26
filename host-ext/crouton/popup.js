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

function updateUI(enabled, debug, hidpi, status, windows) {
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
    /* Update hidpi mode according to checkbox state. */
    var hidpicheck = document.getElementById("hidpicheck");
    if (window.devicePixelRatio > 1) {
        hidpicheck.onclick = function() {
            chrome.runtime.sendMessage({msg: 'HiDPI', data: hidpicheck.checked});
        }
        hidpicheck.disabled = false;
    } else {
        hidpicheck.disabled = true;
    }
    hidpicheck.checked = hidpi;

    /* Update status box */
    document.getElementById("info").textContent = status;

    /* Update window table */
    /* FIXME: Improve UI (nah not gonna happen) */
    var windowlist = document.getElementById("windowlist");

    while (windowlist.rows.length > 0) {
        windowlist.deleteRow(0);
    }

    for (var i = 0; i < windows.length; i++) {
        var row = windowlist.insertRow(-1);
        var cell1 = row.insertCell(0);
        var cell2 = row.insertCell(1);
        cell1.className = "display";
        cell1.innerHTML = windows[i].display;
        cell2.className = "name";
        cell2.innerHTML = windows[i].name;
        cell2.onclick = (function(i) { return function() {
            if (active_) {
                chrome.runtime.sendMessage({msg: 'Window', data: windows[i].display});
                //FIXME: Figure out how to close the popup
                //closePopup();
            }
        } })(i);
    }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    console.log("POPUP rcv message " + message.msg)
    if (message.msg == "updateUI") {
        updateUI(message.data.enabled, message.data.debug, message.data.hidpi, message.data.status, message.data.windows)
    }
});