/* Copyright (c) 2016 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */
'use strict';

// Copy-paste from background.js...
var LogLevel = Object.freeze({
    ERROR : "error",
    INFO  : "info",
    DEBUG : "debug"
});

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

function updateUI(enabled, debug, hidpi, status, windows, showlog, logger) {
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

    /* Update logger table */
    var loggertable = document.getElementById("logger");

    /* FIXME: only update needed rows */
    while (loggertable.rows.length > 0) {
        loggertable.deleteRow(0);
    }

    /* Only update if "show log" is enabled */
    var logcheck = document.getElementById("logcheck");
    logcheck.onclick = function() {
        chrome.runtime.sendMessage({msg: 'Logger', data: logcheck.checked});
    }
    logcheck.checked = showlog;
    if (showlog) {
        for (var i = 0; i < logger.length; i++) {
            var value = logger[i];

            if (value[0] == LogLevel.DEBUG && !debug)
                continue;

            var row = loggertable.insertRow(-1);
            var cell1 = row.insertCell(0);
            var cell2 = row.insertCell(1);
            var levelclass = value[0];
            cell1.className = "time " + levelclass;
            cell2.className = "value " + levelclass;
            cell1.innerHTML = value[1];
            cell2.innerHTML = value[2];
        }
    }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    console.log("POPUP rcv message " + message.msg)
    if (message.msg == "updateUI") {
        updateUI(message.data.enabled, message.data.debug, message.data.hidpi, message.data.status, message.data.windows,
            message.data.showlog, message.data.logger)
    }
});