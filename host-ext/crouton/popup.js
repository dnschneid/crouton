/* Copyright (c) 2015 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */
'use strict';

document.addEventListener('DOMContentLoaded', function() {
    chrome.extension.getBackgroundPage().refreshUI();
});
