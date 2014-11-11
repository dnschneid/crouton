// Copyright (c) 2014 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

var CLOSE_TIMEOUT = 2; /* Close window x seconds after disconnect */
var DEBUG_LEVEL = 2; /* If debug is enabled, use this level in NaCl */
var RESIZE_RATE_LIMIT = 300; /* No more than 1 resize query every x ms */

var KiwiModule_ = null; /* NaCl module */
var listener_ = null; /* listener div element */
var debug_ = 0; /* Debuging level, passed to NaCl module */
var hidpi_ = 0; /* HiDPI mode */
var display_ = null; /* Display number to use */
var title_ = "crouton in a tab"; /* window title */
var connected_ = false;
var closing_ = false; /* Disconnected, and waiting for the window to close */

 /* Rate limit resize events */
var resizePending_ = false;
var resizeLimited_ = false;

function registerWindow(register) {
    chrome.extension.getBackgroundPage().
        registerKiwi(display_, register ? window : null);
}

/* NaCl module loaded */
function moduleDidLoad() {
    KiwiModule_ = document.getElementById('kiwi');
    updateStatus('Starting...');
    kiwiResize();
    KiwiModule_.postMessage('display:' + display_);
    KiwiModule_.postMessage('debug:' + debug_);
    KiwiModule_.postMessage('hidpi:' + hidpi_);
    KiwiModule_.focus();
}

/* NaCl is loading... */
function handleProgress(event) {
    /* We could compute a percentage, but loading gets stuck at 89% (while
     * translating?), so it's not very useful... */
    updateStatus('Loading...');
}

/* NaCl module failed to load */
function handleError(event) {
    // We can't use common.naclModule yet because the module has not been
    // loaded.
    KiwiModule_ = document.getElementById('kiwi');
    updateStatus('ERROR: ' + KiwiModule_.lastError);
    registerWindow(false);
}

/* NaCl module crashed */
function handleCrash(event) {
    if (KiwiModule_.exitStatus == -1) {
        updateStatus('NaCl module crashed.');
    } else {
        updateStatus('NaCl module exited: ' + KiwiModule_.exitStatus);
    }
    registerWindow(false);
}

/* Change debugging level */
function setDebug(debug) {
    debug_ = (debug > 0) ? DEBUG_LEVEL : 0;
    if (debug_ > 0) {
        document.getElementById('content').style.paddingTop = "16px";
        document.getElementById('header').style.display = 'block';
    } else {
        document.getElementById('content').style.paddingTop = "0px";
        document.getElementById('header').style.display = 'none';
    }
    if (KiwiModule_) {
        KiwiModule_.postMessage('debug:' + debug_);
        kiwiResize();
    }
}

/* Change HiDPI mode */
function setHiDPI(hidpi) {
    hidpi_ = hidpi;
    if (KiwiModule_) {
        KiwiModule_.postMessage('hidpi:' + hidpi_);
        kiwiResize();
    }
}

function setTitle(title) {
    document.title = "crouton in a tab: " + title + " (" + display_ + ")";
}

function updateStatus(message) {
    var status = document.getElementById('status');
    if (status) {
        status.textContent = message;
        status.style.display = connected_ ? 'none' : 'block';
    }
}

/* This function is called when a message is received from the NaCl module. */
/* Message format is type:payload */
function handleMessage(message) {
    var str = message.data;
    var type, payload, i;
    if ((i = str.indexOf(":")) > 0) {
        type = str.substr(0, i);
        payload = str.substr(i+1);
    } else {
        type = "debug";
        payload = str;
    }

    console.log(message.data);

    if (type == "debug") {
        var debugEl = document.getElementById('debug');
        if (debugEl)
            debugEl.textContent = message.data;
    } else if (type == "status") {
        updateStatus(payload);
    } else if (type == "connected") {
        connected_ = true;
        updateStatus("Connected");
    } else if (type == "disconnected") {
        connected_ = false;
        if (debug_ < 1) {
            closing_ = true;
            updateStatus("Disconnected, closing window in " +
                         CLOSE_TIMEOUT + " seconds.");
            setTimeout(function() { window.close() }, CLOSE_TIMEOUT*1000);
        } else {
            updateStatus("Disconnected, please close the window.");
        }
        registerWindow(false);
    } else if (type == "state" && payload == "fullscreen") {
        /* Toggle full screen */
        chrome.windows.getCurrent(function(win) {
            var newstate = (win.state == "fullscreen") ?
                               "maximized" : "fullscreen";
            chrome.windows.update(chrome.windows.WINDOW_ID_CURRENT,
                                  {'state': newstate}, function(win) {})
        })
    } else if (type == "state" && payload == "hide") {
        /* Hide window */
        chrome.windows.getCurrent(function(win) {
            minimize = function(win) {
                chrome.windows.update(chrome.windows.WINDOW_ID_CURRENT,
                                      {'state': 'minimized'}, function(win) {})}
            /* To make restore nicer, first exit full screen, then minimize */
            if (win.state == "fullscreen") {
                chrome.windows.update(chrome.windows.WINDOW_ID_CURRENT,
                                      {'state': 'maximized'}, minimize)
            } else {
                minimize()
            }
        })
    } else if (type == "resize") {
        i = payload.indexOf("/");
        if (i < 0) return;
        /* FIXME: Show scroll bars if the window is too small */
        var width = payload.substr(0, i);
        var height = payload.substr(i+1);
        var lwidth = listener_.clientWidth;
        var lheight = listener_.clientHeight;
        var marginleft = (lwidth-width)/2;
        var margintop = (lheight-height)/2;
        KiwiModule_.style.marginLeft = Math.max(marginleft, 0) + "px";
        KiwiModule_.style.marginTop = Math.max(margintop, 0) + "px";
        KiwiModule_.width = width;
        KiwiModule_.height = height;
    }
}

/* Tell the module that the window was resized (this triggers a change of
 * resolution, followed by a resize message. */
function kiwiResize() {
    console.log("resize! " + listener_.clientWidth + "/" + listener_.clientHeight);
    if (KiwiModule_)
        KiwiModule_.postMessage('resize:' + listener_.clientWidth + "/" + listener_.clientHeight);
}

/* Window was resize, limit to one event per second */
function handleResize() {
    if (!resizeLimited_) {
        kiwiResize();
        setTimeout(function() {
            if (resizePending_)
                kiwiResize();
            resizeLimited_ = resizePending_ = false;
        }, RESIZE_RATE_LIMIT);
        resizeLimited_ = true;
    } else {
        resizePending_ = true;
    }
}

/* Called when window changes focus/visiblity */
function handleFocusBlur(evt) {
    /* Unfortunately, hidden/visibilityState is not able to tell when a window
     * is not visible at all (e.g. in the background).
     * See http://crbug.com/403061 */
    console.log("focus/blur: " + evt.type + ", focus=" + document.hasFocus() +
                ", hidden=" + document.hidden + "/" + document.visibilityState);
    if (!KiwiModule_)
        return;

    if (document.hasFocus()) {
        KiwiModule_.postMessage("focus:");
    } else {
        if (closing_)
            window.close();

        if (!document.hidden)
            KiwiModule_.postMessage("blur:");
        else
            KiwiModule_.postMessage("hide:");
    }
    console.log("active: " + document.activeElement);
    KiwiModule_.focus();
}

/* Start in full screen */
chrome.windows.update(chrome.windows.WINDOW_ID_CURRENT,
                      {'state': "fullscreen"}, function(win) {})

document.addEventListener('DOMContentLoaded', function() {
    listener_ = document.getElementById('listener');
    listener_.addEventListener('load', moduleDidLoad, true);
    listener_.addEventListener('progress', handleProgress, true);
    listener_.addEventListener('error', handleError, true);
    listener_.addEventListener('crash', handleCrash, true);
    listener_.addEventListener('message', handleMessage, true);
    window.addEventListener('resize', handleResize);
    window.addEventListener('focus', handleFocusBlur);
    window.addEventListener('blur', handleFocusBlur);
    document.addEventListener('visibilitychange', handleFocusBlur);

    /* Parse arguments */
    var args = location.search.substring(1).split('&');
    display_ = -1;
    debug_ = 0;
    for (var i = 0; i < args.length; i++) {
        var keyval = args[i].split('=')
        if (keyval[0] == "display")
            display_ = keyval[1];
        else if (keyval[0] == "title")
            title_ = decodeURIComponent(keyval[1]);
        else if (keyval[0] == "debug")
            setDebug(keyval[1]);
        else if (keyval[0] == "hidpi")
            setHiDPI(keyval[1]);
    }

    setTitle(title_);

    registerWindow(true);
})
