"use strict";
// The background uses Firefox's sender.documentId to inject a USER stylesheet.
// Page JS supplies neither document identity nor policy, and gets no native bridge.
browser.runtime.connect({name:"cosmetics"});
