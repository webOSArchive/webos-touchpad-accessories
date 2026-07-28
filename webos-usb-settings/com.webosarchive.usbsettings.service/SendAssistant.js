// send -- write one whitelisted command word to the daemon's control file.
if (typeof require === "undefined") { require = IMPORTS.require; }
var fs = require("fs");

var CONTROL = "/media/internal/.usbctl-control";
var ALLOWED = {
    "otg-host": 1, "otg-peripheral": 1,
    "power-on": 1, "power-off": 1,
    "mount": 1, "unmount": 1, "refresh": 1
};

var SendAssistant = function() {};

SendAssistant.prototype.run = function(future) {
    var cmd = this.controller.args && this.controller.args.command;
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
