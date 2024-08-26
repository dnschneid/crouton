// Copyright (c) 2016 The crouton Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
'use strict';

/* Constants */
var URL = "ws://localhost:30001/";
var VERSION = 2; /* Note: the extension must always be backward compatible */
var MAXLOGGERLEN = 20;
var RETRY_TIMEOUT = 5;
var UPDATE_CHECK_INTERVAL = 15*60; /* Check for updates every 15' at most */
var WINDOW_UPDATE_INTERVAL = 15; /* Update window list every 15" at most */
/* String to copy to the clipboard if it should be empty */
var DUMMY_EMPTYSTRING = "%";

var LogLevel = Object.freeze({
    ERROR : "error",
    INFO  : "info",
    DEBUG : "debug"
});

/* Global variables */
var clipboardholder_; /* textarea used to hold clipboard content */
var timeout_ = null; /* Set if a timeout is active */
var websocket_ = null; /* Active connection */

/* State variables */
var debug_ = false;
var showlog_ = false; /* true if extension log should be shown */
var hidpi_ = false; /* true if kiwi windows should be opened in HiDPI mode */
var enabled_ = true; /* true if we are trying to connect */
var active_ = false; /* true if we are connected to a server */
var error_ = false; /* true if there was an error during the last connection */
var dummystr_ = false; /* true if the last string we copied was the dummy string */
var update_ = false; /* true if an update to the extension is available */

var lastupdatecheck_ = null;
var lastwindowlistupdate_ = null;

var status_ = "";
var sversion_ = 0; /* Version of the websocket server */
var logger_ = []; /* Array of status messages: [LogLevel, time, message] */
var windows_ = []; /* Array of windows. (.display, .name) */

var kiwi_win_ = {}; /* Map of kiwi windows. Key is display, value is object
                        (.id, .isTab, .window: window element) */
var focus_win_ = -1; /* Focused kiwi window. -1 if no kiwi window focused. */

var notifications_ = {}; /* Map of notification id to function to be called when
                            the notification is clicked. */

/* Check local storage for stored options */
chrome.storage.local.get(null, function(items){
    if (typeof items.enabled == "boolean") enabled_ = items.enabled;
    if (typeof items.hidpi == "boolean") hidpi_ = items.hidpi;
    refreshUI();
});

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
    chrome.tabs.create({url:"first.html", active:true});
}

function updateAvailable(version) {
    printLog("A new version of the extension is available (" + version + ")",
             LogLevel.INFO);

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

function updateWindowList(force) {
    if (!active_ || sversion_ < 2) {
        windows_ = [];
        return;
    }

    var currenttime = new Date().getTime();

    if (force || lastwindowlistupdate_ == null ||
            (currenttime-lastwindowlistupdate_) > 1000*WINDOW_UPDATE_INTERVAL) {
        lastwindowlistupdate_ = currenttime;
        printLog("Sending window list request", LogLevel.DEBUG);
        websocket_.send("Cs" + focus_win_);
        websocket_.send("Cl");
    }
}

/* Called from kiwi (window.js), so we can directly access each window */
function registerKiwi(displaynum, window) {
    var display = ":" + displaynum;
    if (kiwi_win_[display] && kiwi_win_[display].id >= -1) {
        kiwi_win_[display].window = window;
    }
}

/* Close the popup window */
function closePopup() {
    var views = []
    //FIXME: figure out how to replace getViews with getContexts
    //chrome.extension.getViews({type: "popup"});
    //chrome.runtime.getContexts({contextTypes: ['POPUP']})
    for (var i = 0; i < views.length; views++) {
        views[i].close();
    }
}

/* Update the icon, and refresh the popup page */
function refreshUI() {
    updateWindowList(false);

    var icon = "disconnected";
    if (error_)
        icon = "error";
    else if (!enabled_)
        icon = "disabled";
    else if (active_)
        icon = "connected";

    chrome.action.setIcon(
        {path: {19: icon + '-19.png', 38: icon + '-38.png'}}
    );
    chrome.action.setTitle({title: 'crouton: ' + icon});

    chrome.action.setBadgeText(
        {text: windows_.length > 1 ? '' + (windows_.length-1) : ''}
    );
    chrome.action.setBadgeBackgroundColor({color: '#2E822B'});

    var views = []
    //FIXME: figure out how to replace getViews with getContexts
    //chrome.extension.getViews({type: "popup"});
    chrome.runtime.getContexts({contextTypes: ['POPUP']}).then(
        (contexts) => {
            if (contexts.length == 0) {
                console.log("No popup listens to me.")
                return
            }
            chrome.runtime.sendMessage({msg: 'updateUI', data: {enabled: enabled_, debug: debug_}})
        }
    )
    for (var i = 0; i < views.length; views++) {
        var view = views[i];
        /* Make sure page is ready */
        if (view.document.readyState != "loading") {
            /* Update hidpi mode according to checkbox state. */
            var hidpicheck = view.document.getElementById("hidpicheck");
            if (window.devicePixelRatio > 1) {
                hidpicheck.onclick = function() {
                    hidpi_ = hidpicheck.checked;
                    /* Update local storage to persist hidpi_ setting */
                    chrome.storage.local.set({hidpi: hidpi_});
                    refreshUI();
                    var disps = Object.keys(kiwi_win_);
                    for (var i = 0; i < disps.length; i++) {
                        var win = kiwi_win_[disps[i]];
                        if (win.window) {
                            if (win.isTab) {
                                chrome.tabs.sendMessage(win.id,
                                        {func: 'setHiDPI', param: hidpi_?1:0});
                            } else {
                                win.window.setHiDPI(hidpi_?1:0);
                            }
                        }
                    }
                }
                hidpicheck.disabled = false;
            } else {
                hidpicheck.disabled = true;
            }
            hidpicheck.checked = hidpi_;

            /* Update status box */
            view.document.getElementById("info").textContent = status_;

            /* Update window table */
            /* FIXME: Improve UI */
            var windowlist = view.document.getElementById("windowlist");

            while (windowlist.rows.length > 0) {
                windowlist.deleteRow(0);
            }

            for (var i = 0; i < windows_.length; i++) {
                var row = windowlist.insertRow(-1);
                var cell1 = row.insertCell(0);
                var cell2 = row.insertCell(1);
                cell1.className = "display";
                cell1.innerHTML = windows_[i].display;
                cell2.className = "name";
                cell2.innerHTML = windows_[i].name;
                cell2.onclick = (function(i) { return function() {
                    if (active_) {
                        websocket_.send("C" + windows_[i].display);
                        closePopup();
                    }
                } })(i);
            }

            /* Update logger table */
            var loggertable = view.document.getElementById("logger");

            /* FIXME: only update needed rows */
            while (loggertable.rows.length > 0) {
                loggertable.deleteRow(0);
            }

            /* Only update if "show log" is enabled */
            var logcheck = view.document.getElementById("logcheck");
            logcheck.onclick = function() {
                showlog_ = logcheck.checked;
                refreshUI();
            }
            logcheck.checked = showlog_;
            if (showlog_) {
                for (var i = 0; i < logger_.length; i++) {
                    var value = logger_[i];

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
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    console.log("SERVICE rcv message " + message.msg)
    if (message.msg == "showHelp") {
        showHelp();
    } else if (message.msg == "refreshUI") {
        refreshUI();
    } else if (message.msg == "Disable") {
        console.log("Disable click");
        enabled_ = false;
        /* Update local storage to persist enabled_ boolean */
        chrome.storage.local.set({enabled: enabled_});
        if (websocket_ != null)
            websocket_.close();
        else
            websocketConnect(); /* Clear timeout and display message */
        refreshUI();
    } else if (message.msg == "Enable") {
        console.log("Enable click");
        enabled_ = true;
        /* Update local storage to persist enabled_ boolean */
        chrome.storage.local.set({enabled: enabled_});
        if (websocket_ == null)
            websocketConnect();
        refreshUI();
    } else if (message.msg == "Debug") {
        debug_ = message.data;
        refreshUI();
        var disps = Object.keys(kiwi_win_);
        for (var i = 0; i < disps.length; i++) {
            var win = kiwi_win_[disps[i]];
            if (win.window) {
                if (win.isTab) {
                    chrome.tabs.sendMessage(win.id,
                            {func: 'setDebug', param: debug_?1:0});
                } else {
                    win.window.setDebug(debug_?1:0);
                }
            }
        }
    }
});

/* Start the extension */
function clipboardStart() {
    printLog("Extension started (" + chrome.runtime.getManifest().version + ")",
             LogLevel.INFO);
    setStatus("Started...", false);

    /* Monitor window/tab focus changes/removals and report to croutonclip */
    chrome.windows.onFocusChanged.addListener(
            function(id) { onFocusChanged(id, false); });
    chrome.windows.onRemoved.addListener(
            function(id) { onRemoved(id, false); });
    chrome.tabs.onActivated.addListener(
            function(data) { onFocusChanged(data.tabId, true); });
    chrome.tabs.onRemoved.addListener(
            function(id, data) { onRemoved(id, true); });

    /* FIXME: create a background document
    clipboardholder_ = document.getElementById("clipboardholder");
    */

    /* Notification event handlers */
    chrome.notifications.onClosed.addListener(notificationClosed);
    chrome.notifications.onClicked.addListener(notificationClicked);

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
        setStatus("No connection (extension disabled)", false);
        printLog("Extension is disabled", LogLevel.INFO);
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
    printLog("Connection established", LogLevel.INFO);
    setStatus("Connected: checking version...", false);
}

function readClipboard() {
    /* FIXME: create a background document
    clipboardholder_.value = "";
    clipboardholder_.select();
    document.execCommand("Paste");
    return clipboardholder_.value;
    */
    return "";
}

function writeClipboard(str) {
    /* FIXME: create a background document
    clipboardholder_.value = str;
    clipboardholder_.select();
    document.execCommand("Copy");
    */
}

/* Received a message from the server */
function websocketMessage(evt) {
    var received_msg = evt.data;
    var cmd = received_msg[0];
    var payload = received_msg.substring(1);

    printLog("Message received (" + received_msg + ")", LogLevel.DEBUG);

    /* Only accept version packets until we have received one. */
    if (!active_) {
        if (cmd == 'V') { /* Version */
            sversion_ = payload;
            if (sversion_ < 1 || sversion_ > VERSION) {
                websocket_.send("EInvalid version (> " + VERSION + ")");
                error("Invalid server version " + sversion_ + " > " + VERSION,
                      false);
            }
            websocket_.send("VOK");
            /* Set active_ to true */
            setStatus(sversion_ >= 2 ? "" : "Connected", true);
            /* Force a window list update */
            updateWindowList(true);
            return;
        } else {
            error("Received frame while waiting for version", false);
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
            printLog("Not erasing content (identical)", LogLevel.DEBUG);
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
            chrome.tabs.create({url: payload});
            websocket_.send("UOK");
        } else {
            printLog("Received invalid URL: " + payload, LogLevel.ERROR);
            websocket_.send("EError: URL must be absolute");
        }

        break;
    case 'N': /* Raise a notification */
        /* Payload in JSON format, compatible with chrome.extensions specifications */
        try {
            var data = JSON.parse(payload);

            if (!data.type)
                data.type = "basic";
            if (!data.iconUrl)
                data.iconUrl = "icon-128.png";

            /* Strip off crouton fields */
            var id = "";
            var display = null;

            if (data.crouton_id) {
                id = data.crouton_id;
            }
            delete data.crouton_id;

            /* Set context message with chroot name/display */
            delete data.contextMessage;
            if (data.crouton_display) {
                display = data.crouton_display;
                var win = windows_.filter(function(x) {
                                              return x.display == display })[0];
                var name = win ? (win.name + " (" + display + ")") : display;
                data.contextMessage = "Switch to " + name;
            }
            delete data.crouton_display;

            chrome.notifications.create(id, data,
                function(id) {
                    printLog("Raised notification " + id, LogLevel.DEBUG);
                    notifications_[id] = function() {
                        if (display)
                            websocket_.send("C" + display);
                        /* Remove the notification. */
                        chrome.notifications.clear(id, function(_) {});
                    }
                });
            websocket_.send("NOK");
        } catch(e) {
            printLog("Notification parsing error: " + e +
                     " (payload: '" + payload + "').", LogLevel.ERROR);
            websocket_.send("EError: invalid payload.");
        }
        break;
    case 'C': /* Returned data from a croutoncycle command */
        /* Non-zero length has a window list; otherwise it's a cycle signal */
        if (payload.length > 0) {
            windows_ = payload.split('\n').map(
                function(x) {
                    var m = x.match(/^([^ *]*)\*? +(.*)$/);
                    if (!m)
                        return null;

                    /* Only display cros and X11 servers (no window) */
                    if (m[1] != "cros" && !m[1].match(/^:([0-9]+)$/))
                        return null;

                    var k = new Object();
                    k.display = m[1];
                    k.name = m[2];
                    return k;
                }
            ).filter( function(x) { return !!x; } );

            windows_.forEach(function(k) {
                var win = kiwi_win_[k.display];
                if (win && win.window) {
                    if (win.isTab) {
                        chrome.tabs.sendMessage(win.id,
                                {func: 'setTitle', param: k.name});
                    } else {
                        win.window.setTitle(k.name);
                    }
                }
            });

            lastwindowlistupdate_ = new Date().getTime();
            websocket_.send("COK");
        }
        refreshUI();
        break;
    case 'X': /* Ask to open a crouton window */
        var display = payload;
        var match = display.match(/^:([0-9]+)([- ][^- ]*)*$/);
        var displaynum = match ? match[1] : null;
        var mode = null;
        if (displaynum) {
            display = ":" + displaynum;
            mode = match[2] && match[2].length >= 2 ? match[2].charAt(1) : 'f';
            if ('fwt'.indexOf(mode) == -1) {
                console.log('invalid xiwi mode: ' + mode);
                mode = 'f';
            }
        }
        if (!displaynum) {
            /* Minimize all kiwi windows  */
            var disps = Object.keys(kiwi_win_);
            for (var i = 0; i < disps.length; i++) {
                if (kiwi_win_[disps[i]].isTab) {
                    continue;
                }
                var winid = kiwi_win_[disps[i]].id;
                chrome.windows.update(winid, {focused: false});

                var minimize = function(win) {
                    chrome.windows.update(winid, {state: 'minimized'}); };

                chrome.windows.get(winid, function(win) {
                    /* To make restore nicer, first exit full screen,
                     * then minimize */
                    if (win.state == "fullscreen") {
                        chrome.windows.update(winid, {state: 'maximized'},
                                              minimize);
                    } else {
                        minimize();
                    }
                });
            }
        } else if (kiwi_win_[display] && kiwi_win_[display].id >= 0 &&
                   (!kiwi_win_[display].window ||
                    !kiwi_win_[display].window.closing)) {
            /* focus/full screen an existing window */
            var winid = kiwi_win_[display].id;
            if (kiwi_win_[display].isTab) {
                chrome.tabs.update(winid, {active: true});
                chrome.tabs.get(winid, function(tab) {
                    chrome.windows.update(tab.windowId, {focused: true});
                });
            } else {
                chrome.windows.update(winid, {focused: true});
                chrome.windows.get(winid, function(win) {
                    if (win.state == "maximized")
                        chrome.windows.update(winid, {state: 'fullscreen'});
                });
            }
        } else {
            /* Open a new window */
            kiwi_win_[display] = new Object();
            kiwi_win_[display].id = -1;
            kiwi_win_[display].isTab = (mode == 't');
            kiwi_win_[display].window = null;

            var win = windows_.filter(function(x){return x.display == display})[0];
            var name = win ? win.name : "crouton in a window";
            var create = chrome.windows.create;
            var data = {};

            if (kiwi_win_[display].isTab) {
                name = win ? win.name : "crouton in a tab";
                create = chrome.tabs.create;
            } else {
                data['type'] = "popup";
            }

            data['url'] = "window.html?display=" + displaynum +
                          "&debug=" + (debug_ ? 1 : 0) +
                          "&hidpi=" + (hidpi_ ? 1 : 0) +
                          "&title=" + encodeURIComponent(name) +
                          "&mode=" + mode;

            create(data, function(newwin) {
                             kiwi_win_[display].id = newwin.id;
                             focus_win_ = display;
                             if (active_ && sversion_ >= 2)
                                 websocket_.send("Cs" + focus_win_);
                         });
        }
        websocket_.send("XOK");
        closePopup();
        /* Force a window list update */
        updateWindowList(true);
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

    printLog("Connection closed", active_ ? LogLevel.INFO : LogLevel.DEBUG);
    if (enabled_) {
        setStatus("Disconnected (retrying every " + RETRY_TIMEOUT + " seconds)",
                  false);
        /* Retry in RETRY_TIMEOUT seconds */
        if (timeout_ == null) {
            timeout_ = setTimeout(websocketConnect, RETRY_TIMEOUT*1000);
        }
    } else {
        setStatus("Disconnected (extension disabled)", false);
    }

    websocket_ = null;

    /* Check for update on every disconnect */
    checkUpdate(false);
}

/* Called when window/tab in focus changes: feedback to the extension so the
 * clipboard can be transfered. */
function onFocusChanged(id, isTab) {
    var disps = Object.keys(kiwi_win_);
    var nextfocus_win = "cros";
    for (var i = 0; i < disps.length; i++) {
        if (kiwi_win_[disps[i]].isTab == isTab
                && kiwi_win_[disps[i]].id == id) {
            nextfocus_win = disps[i];
            break;
        }
    }
    if (focus_win_ != nextfocus_win) {
        focus_win_ = nextfocus_win;
        if (active_ && sversion_ >= 2)
            websocket_.send("Cs" + focus_win_);
        printLog("Window " + focus_win_ + " focused", LogLevel.DEBUG);
    }
}

/* Called when a window/tab is removed, so we can delete its reference. */
function onRemoved(id, isTab) {
    var disps = Object.keys(kiwi_win_);
    for (var i = 0; i < disps.length; i++) {
        if (kiwi_win_[disps[i]].isTab == isTab
                && kiwi_win_[disps[i]].id == id) {
            kiwi_win_[disps[i]].id = -2;
            kiwi_win_[disps[i]].isTab = false;
            kiwi_win_[disps[i]].window = null;
            printLog("Window " + disps[i] + " removed", LogLevel.DEBUG);
            /* Force a window list update */
            updateWindowList(true);
        }
    }
}

/* Called when a notification is clicked */
function notificationClicked(id) {
    printLog("Notification " + id + " clicked.", LogLevel.DEBUG);
    if (notifications_[id]) {
        notifications_[id]();
    }
}

/* Called when a notification is closed */
function notificationClosed(id, byUser) {
    printLog("Notification " + id + " closed (byUser: " + byUser + ").",
             LogLevel.DEBUG);
    delete notifications_[id];
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
    var date = new Date;
    var datestr = padstr0(date.getHours()) + ":" +
                  padstr0(date.getMinutes()) + ":" +
                  padstr0(date.getSeconds());

    if (str.length > 200)
        str = str.substring(0, 197) + "...";
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
    if (websocket != null)
        websocket_.close();
    /* Force check for extension update (possible reason for the error) */
    checkUpdate(true);
}

/* Open help tab on first install on Chromium OS */
chrome.runtime.onInstalled.addListener(function(details) {
    if (details.reason == "install") {
        chrome.runtime.getPlatformInfo(function(platforminfo) {
            if (platforminfo.os == 'cros') {
                showHelp();
            }
        });
    }
});

/* Initialize, taking into account the platform */
chrome.runtime.getPlatformInfo(function(platforminfo) {
    if (platforminfo.os == 'cros') {
        /* On error: disconnect WebSocket, then log errors */
        var onerror = function(msg, url, line) {
            if (websocket_)
                websocket_.close();
            error("Uncaught JS error: " + msg, false);
            return true;
        }

        /* Start the extension as soon as the background page is loaded */
        /* FIXME: create a background document
        if (document.readyState == 'complete') {
            clipboardStart();
        } else {
            document.addEventListener('DOMContentLoaded', clipboardStart);
        }*/

        chrome.runtime.onUpdateAvailable.addListener(function(details) {
            updateAvailable(details.version);
        });
    } else {
        /* Disable the icon on non-Chromium OS. */
        chrome.action.setTitle(
            {title: 'crouton is not available on this platform'}
        );
        chrome.action.disable();
    }
});
