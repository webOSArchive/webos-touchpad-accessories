// send -- app -> daemon. Most commands write one whitelisted word to the control
// file; "watch-on" instead refreshes a keepalive file (a timestamp) that tells
// the daemon to run the device monitor while the panel is open.
if (typeof require === "undefined") { require = IMPORTS.require; }
var fs = require("fs");

var CONTROL = "/media/internal/.usbctl-control";
var WATCH   = "/media/internal/.usbctl-watch";
var ALLOWED = {
    "otg-host": 1, "otg-peripheral": 1,
    "power-on": 1, "power-off": 1,
    "mount": 1, "unmount": 1,
    "reset": 1, "refresh": 1
};

var SendAssistant = function() {};

SendAssistant.prototype.run = function(future) {
    var cmd = this.controller.args && this.controller.args.command;

    // keepalive: refresh the watch file with epoch-seconds; not a daemon command
    if (cmd === "watch-on") {
        try {
            fs.writeFileSync(WATCH, String(Math.floor((new Date()).getTime() / 1000)));
            future.result = { returnValue: true, command: cmd };
        } catch (e) {
            future.result = { returnValue: false, errorText: String(e) };
        }
        return;
    }

    if (!cmd || !ALLOWED[cmd]) {
        future.result = { returnValue: false, errorText: "unknown command" };
        return;
    }
    try {
        fs.writeFileSync(CONTROL, cmd);
        future.result = { returnValue: true, command: cmd };
    } catch (e) {
        future.result = { returnValue: false, errorText: String(e) };
    }
};
