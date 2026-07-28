// getStatus -- read the daemon's status file and return it to the app.
// Node on webOS is v0.2.x (ES5 only); pull require from IMPORTS.
if (typeof require === "undefined") { require = IMPORTS.require; }
var fs = require("fs");

var STATUS = "/media/internal/.usbctl-status";

var GetStatusAssistant = function() {};

GetStatusAssistant.prototype.run = function(future) {
    var out = {
        returnValue: true,
        daemon: false,
        otg: "peripheral",
        power: "off",
        storage: { present: false, mounted: false, dev: "", mountpoint: "" }
    };
    try {
        var raw = fs.readFileSync(STATUS, "utf8");
        var st = (typeof raw === "string") ? raw : raw.toString();
        var obj = JSON.parse(st);
        out.daemon = true;
        if (obj.otg) { out.otg = obj.otg; }
        if (obj.power) { out.power = obj.power; }
        if (obj.storage) { out.storage = obj.storage; }
    } catch (e) {
        // status file missing/unreadable -> daemon not up yet; return defaults
        out.daemon = false;
    }
    future.result = out;
};
