// Copyright (c) 2013 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/* Constants */
var URL = "ws://localhost:30001/";
var VERSION = 1; /* Note: the extension must always be backward compatible */
var MAXLOGGERLEN = 20;
var RETRY_TIMEOUT = 5;
var UPDATE_CHECK_INTERVAL = 15*60; /* Check for updates every 15' at most */
/* String to copy to the clipboard if it should be empty */
var DUMMY_EMPTYSTRING = "%";

LogLevel = {
    ERROR : "error",
    INFO : "info",
    DEBUG : "debug"
}

/* Global variables */
var clipboardholder_; /* textarea used to hold clipboard content */
var timeout_ = null; /* Set if a timeout is active */
var websocket_ = null; /* Active connection */

/* State variables */
var debug_ = false;
var enabled_ = true; /* true if we are trying to connect */
var active_ = false; /* true if we are connected to a server */
var error_ = false; /* true if there was an error during the last connection */
var dummystr_ = false; /* true if the last string we copied was the dummy string */
var update_ = false; /* true if an update to the extension is available */

var lastupdatecheck_ = null;

var status_ = "";
var logger_ = []; /* Array of status messages: [LogLevel, time, message] */

/* Set the current status string.
 * active is a boolean, true if the WebSocket connection is established. */
function setStatus(status, active) {
    active_ = active;
    status_ = status;

    /* Apply update if the extension is not active */
    if (update_ && !active_)
        chrome.runtime.reload();

    refreshUI();
}

function showHelp() {
    chrome.tabs.create({url: "first.html"});
}

function updateAvailable(version) {
    printLog("A new version of the extension is available (" +
             version + ").", LogLevel.INFO);

    /* Apply update immediately if the extension is not active */
    if (!active_)
        chrome.runtime.reload();
    else
        update_ = true;
}

function checkUpdate(force) {
    var currenttime = new Date().getTime();

    if (force || lastupdatecheck_ == null ||
            (currenttime-lastupdatecheck_) > 1000*UPDATE_CHECK_INTERVAL) {
        chrome.runtime.requestUpdateCheck(function (status, details) {
            printLog("Update status=" + status, LogLevel.DEBUG);
            if (status == "update_available") {
                updateAvailable(details.version);
            }
        });
        lastupdatecheck_ = currenttime;
    }
}

/* Update the icon, and refresh the popup page */
function refreshUI() {
    if (error_)
        icon = "error"
    else if (!enabled_)
        icon = "disabled"
    else if (active_)
        icon = "connected";
    else
        icon = "disconnected";

    chrome.browserAction.setIcon(
        {path: {'19': icon + '-19.png', '38': icon + '-38.png'}}
    );

    var views = chrome.extension.getViews({type: "popup"});
    for (var i = 0; i < views.length; views++) {
        /* Make sure page is ready */
        if (document.readyState === "complete") {
            /* Update "help" link */
            helplink = views[i].document.getElementById("help");
            helplink.onclick = showHelp;
            /* Update enable/disable link. */
            /* FIXME: Sometimes, there is a little box coming around the link */
            enablelink = views[i].document.getElementById("enable");
            if (enabled_) {
                enablelink.textContent = "Disable";
                enablelink.onclick = function() {
                    console.log("Disable click");
                    enabled_ = false;
                    if (websocket_ != null)
                        websocket_.close();
                    else
                        websocketConnect(); /* Clear timeout and display message */
                    refreshUI();
                }
            } else {
                enablelink.textContent = "Enable";
                enablelink.onclick = function() {
                    console.log("Enable click");
                    enabled_ = true;
                    if (websocket_ == null)
                        websocketConnect();
                    refreshUI();
                }
            }

            /* Update debug mode according to checkbox state. */
            debugcheck = views[i].document.getElementById("debugcheck");
            debugcheck.onclick = function() {
                debug_ = debugcheck.checked;
                refreshUI();
            }
            debugcheck.checked = debug_;

            /* Update status box */
            views[i].document.getElementById("info").textContent = status_;

            /* Update logger table */
            loggertable = views[i].document.getElementById("logger");

            /* FIXME: only update needed rows */
            while (loggertable.rows.length > 0) {
                loggertable.deleteRow(0);
            }

            for (i = 0; i < logger_.length; i++) {
                value = logger_[i];

                if (value[0] == LogLevel.DEBUG && !debug_)
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
}

/* Start the extension */
function clipboardStart() {
    printLog("Crouton extension started (" +
             chrome.runtime.getManifest().version + ")!", LogLevel.INFO);
    setStatus("Started...", false);

    clipboardholder_ = document.getElementById("clipboardholder");

    websocketConnect();
}

/* Connect to the server */
function websocketConnect() {
    /* Clear timeout if we were called manually. */
    if (timeout_ != null) {
        clearTimeout(timeout_);
        timeout_ = null;
    }

    if (!enabled_) {
        setStatus("No connection (extension disabled).", false);
        printLog("Extension is disabled.", LogLevel.INFO);
        return;
    }

    if (websocket_ != null) {
        printLog("Socket already open", LogLevel.DEBUG);
        return;
    }

    console.log("websocketConnect: " + websocket_);

    printLog("Opening a web socket", LogLevel.DEBUG);
    error_ = false;
    setStatus("Connecting...", false);
    websocket_ = new WebSocket(URL);
    websocket_.onopen = websocketOpen;
    websocket_.onmessage = websocketMessage;
    websocket_.onclose = websocketClose;
}

/* Connection was established */
function websocketOpen() {
    printLog("Connection established.", LogLevel.INFO);
    setStatus("Connection established: checking version...", false);
}

function readClipboard() {
    clipboardholder_.value = "";
    clipboardholder_.select();
    document.execCommand("Paste");
    return clipboardholder_.value;
}

function writeClipboard(str) {
    clipboardholder_.value = str;
    clipboardholder_.select();
    document.execCommand("Copy");
}

/* Received a message from the server */
function websocketMessage(evt) {
    var received_msg = evt.data;
    var cmd = received_msg[0];
    var payload = received_msg.substring(1);

    printLog("Message is received (" + received_msg + ")", LogLevel.DEBUG);

    /* Only accept version packets until we have received one. */
    if (!active_) {
        if (cmd == 'V') { /* Version */
            if (payload < 1 || payload > VERSION) {
                websocket_.send("EInvalid version (> " + VERSION + ")");
                error("Invalid server version " +
                                payload + " > " + VERSION + ".", false);
            }
            /* Set active_ to true */
            setStatus("Connection established.", true);
            websocket_.send("VOK");
            return;
        } else {
            error("Received frame while waiting for version.", false);
        }
    }

    switch(cmd) {
    case 'W': /* Write */
        var clip = readClipboard();

        dummystr_ = false;

        /* Do not erase identical clipboard content */
        if (clip != payload) {
             /* We cannot write an empty string: Write DUMMY instead */
            if (payload == "") {
                writeClipboard(DUMMY_EMPTYSTRING);
                dummystr_ = true;
            } else {
                writeClipboard(payload);
            }
        } else if (payload == DUMMY_EMPTYSTRING) {
            /* Unlikely case where DUMMY string comes from the other side */
            writeClipboard(payload);
        } else {
            printLog("Not erasing content (identical).", LogLevel.DEBUG);
        }

        websocket_.send("WOK");

        break;
    case 'R': /* Read */
        var clip = readClipboard();

        if (clip == DUMMY_EMPTYSTRING && dummystr_) {
            websocket_.send("R");
        } else {
            websocket_.send("R" + clip);
        }

        break;
    case 'U': /* Open an URL */
        /* URL must be absolute: see RFC 3986 for syntax (section 3.1) */
        if (match = (/^([a-z][a-z0-9+-.]*):/i).exec(payload)) {
            /* FIXME: we could blacklist schemes using match[1] here */
            chrome.tabs.create({ url: payload });
            websocket_.send("UOK");
        } else {
            printLog("Received invalid URL: " + payload, LogLevel.ERROR);
            websocket_.send("EError: URL must be absolute.");
        }

        break;
    case 'P': /* Ping */
        websocket_.send(received_msg);
        break;
    case 'E':
        error("Server error: " + payload, 1);
        break;
    default:
        error("Invalid packet from server: " + received_msg, 1);
        break;
    }
}

/* Connection was closed (or never established) */
function websocketClose() {
    if (websocket_ == null) {
        console.log("websocketClose: null!");
        return;
    }

    if (enabled_) {
        setStatus("No connection (retrying in " +
                                    RETRY_TIMEOUT + " seconds)", false);
        printLog("Connection is closed, trying again in " +
                            RETRY_TIMEOUT + " seconds...", LogLevel.INFO);
        /* Retry in RETRY_TIMEOUT seconds */
        if (timeout_ == null) {
            timeout_ = setTimeout(websocketConnect, RETRY_TIMEOUT*1000);
        }
    } else {
        setStatus("No connection (extension disabled).", false);
        printLog("Connection is closed, extension is disabled: not retrying.",
                                                            LogLevel.INFO);
    }

    websocket_ = null;

    /* Check for update on every disconnect */
    checkUpdate(false);
}

function padstr0(i) {
    var s = i + "";
    if (s.length < 2)
        return "0" + s;
    else
        return s;
}

/* Add a message in the log. */
function printLog(str, level) {
    date = new Date;
    datestr = padstr0(date.getHours()) + ":" +
              padstr0(date.getMinutes()) + ":" +
              padstr0(date.getSeconds());

    if (str.length > 80)
        str = str.substring(0, 77) + "...";
    console.log(datestr + ": " + str);

    /* Add messages to logger */
    if (level != LogLevel.DEBUG || debug_) {
        logger_.unshift([level, datestr, str]);
        if (logger_.length > MAXLOGGERLEN) {
            logger_.pop();
        }
        refreshUI();
    }
}

/* Display an error, and prevent retries if enabled is false */
function error(str, enabled) {
    printLog(str, LogLevel.ERROR);
    enabled_ = enabled;
    error_ = true;
    refreshUI();
    websocket_.close();
    /* Force check for extension update (possible reason for the error) */
    checkUpdate(true);
}

/* On error: disconnect WebSocket, then log errors */
onerror = function(msg, url, line) {
    if (websocket_)
        websocket_.close();
    error("Uncaught JS error: " + msg, false);
    return true;
}

/* Start the extension as soon as the background page is loaded */
document.addEventListener('DOMContentLoaded', clipboardStart);

chrome.runtime.onInstalled.addListener(function(details) {
    if (details.reason == "install") {
        /* Open help tab on first install */
        showHelp();
    }
}
)

chrome.runtime.onUpdateAvailable.addListener(function(details) {
    updateAvailable(details.version);
});
