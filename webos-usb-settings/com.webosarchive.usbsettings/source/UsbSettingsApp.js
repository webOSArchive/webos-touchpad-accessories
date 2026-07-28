enyo.kind({
	name: "UsbSettingsApp",
	kind: "VFlexBox",
	components: [
		{kind: "Toolbar", className: "enyo-toolbar-light accounts-header", pack: "center", components: [
			{kind: "Image", src: "images/usbsettings_48x48.png", className: "icon-image"},
			{kind: "Control", content: $L("USB Settings")},
			/* spinner shown while an operation is in flight (like the Wi-Fi app) */
			{kind: "Spinner", name: "titleSpinner", className: "usb-title-spinner", showing: false}
		]},
		{className: "accounts-header-shadow"},
		{kind: "Scroller", flex: 1, components: [
			{kind: "Pane", flex: 1, components: [
				{kind: "HFlexBox", name: "loadingView", className: "box-center enyo-bg", flex: 1, pack: "center", align: "center", components: [
					{kind: "Spinner", name: "spinner"},
					{content: $L("Loading…")}
				]},
				{kind: "Control", name: "prefView", className: "box-center enyo-bg", components: [

					/* --- daemon-missing warning (hidden unless needed) --- */
					{kind: "RowGroup", name: "warnGroup", className: "accounts-group", showing: false, components: [
						{kind: "Item", tapHighlight: false, components: [
							{name: "warnText", className: "text-truncation",
							 content: $L("Helper not running. Install via Preware and reboot.")}
						]}
					]},

					/* --- USB Host (OTG) --- */
					{kind: "RowGroup", className: "accounts-group", caption: $L("USB Host"), components: [
						{kind: "Item", tapHighlight: false, layoutKind: "HFlexLayout", components: [
							{flex: 1, content: $L("USB host mode")},
							{kind: "ToggleButton", name: "otgToggle", onChange: "toggleOtg"}
						]}
					]},
					{className: "accounts-body-text",
					 content: $L("Turn on to use USB keyboards, game controllers and drives. While on, USB charging and USB computer sync are unavailable.")},

					/* --- High power --- */
					{kind: "RowGroup", className: "accounts-group", caption: $L("Power"), components: [
						{kind: "Item", tapHighlight: false, layoutKind: "HFlexLayout", components: [
							{flex: 1, content: $L("High-power devices")},
							{kind: "ToggleButton", name: "powerToggle", onChange: "togglePower"}
						]}
					]},
					{className: "accounts-body-text",
					 content: $L("Allow devices that draw more power than the port normally permits, such as a DualShock 4 controller. Turn on before plugging the device in.")},

					/* --- USB Storage --- */
					{kind: "RowGroup", className: "accounts-group", caption: $L("USB Storage"), components: [
						{kind: "Item", tapHighlight: false, layoutKind: "HFlexLayout", components: [
							{flex: 1, content: $L("Drive")},
							{name: "storageStatus", content: $L("None")}
						]},
						{kind: "Item", name: "storageBtnRow", tapHighlight: true, layoutKind: "HFlexLayout", onclick: "toggleStorage", components: [
							{flex: 1, name: "storageBtnLabel", content: $L("Mount")}
						]}
					]},
					/* dynamic explainer under the storage section -- shows WHERE it's mounted */
					{name: "storageHelp", className: "accounts-body-text",
					 content: $L("Plug in a USB flash drive, then tap Mount to browse it. Always unmount before unplugging.")}
				]}
			]}
		]},

		{kind: "AppMenu", components: [
			{kind: "HelpMenu", target: "https://github.com/webOSArchive"}
		]},

		/* our own bridge service (writes control file / reads status) */
		{kind: "PalmService", name: "svc", service: "palm://com.webosarchive.usbsettings.service/", components: [
			{name: "getStatus", method: "getStatus", onSuccess: "handleStatus", onFailure: "handleSvcFail"},
			{name: "send", method: "send", onFailure: "handleSvcFail"}
		]}
	],

	create: function() {
		this.inherited(arguments);
		this.updating = false;      // guards poll-driven setState from re-firing onChange
		this.havePrefs = false;
		this.opInFlight = false;    // an operation is running -> show title spinner
		this.prevPresent = null;    // for detect/remove banners
		this.prevMounted = null;    // for mount/unmount banners
		this.$.spinner.show();
		this.refresh();
		this.pollTimer = window.setInterval(enyo.bind(this, "refresh"), 2500);
	},

	refresh: function() {
		this.$.getStatus.call({});
	},

	// webOS dashboard/banner notification (top-of-screen). No-op off-device.
	banner: function(msg) {
		try {
			if (window.PalmSystem && window.PalmSystem.addBannerMessage) {
				window.PalmSystem.addBannerMessage(msg, "{}", "images/mini-icon.png", "");
			}
		} catch (e) {}
	},

	startOp: function() {
		this.opInFlight = true;
		this.$.titleSpinner.show();
	},

	handleStatus: function(inSender, r) {
		this.updating = true;
		this.$.warnGroup.setShowing(!r.daemon);
		this.$.otgToggle.setState(r.otg === "host");
		this.$.powerToggle.setState(r.power === "on");

		var st = r.storage || {};
		var present = !!st.present, mounted = !!st.mounted;

		if (!present) {
			this.$.storageStatus.setContent($L("None"));
			this.$.storageBtnLabel.setContent($L("Mount"));
			this.$.storageBtnRow.setDisabled(true);
			this.$.storageHelp.setContent($L("Plug in a USB flash drive, then tap Mount to browse it. Always unmount before unplugging."));
		} else {
			this.$.storageStatus.setContent(mounted ? $L("Mounted") : $L("Not mounted"));
			this.$.storageBtnLabel.setContent(mounted ? $L("Unmount") : $L("Mount"));
			this.$.storageBtnRow.setDisabled(false);
			if (mounted && st.mountpoint) {
				this.$.storageHelp.setContent($L("Mounted to ") + st.mountpoint + $L(" — always unmount before unplugging."));
			} else {
				this.$.storageHelp.setContent($L("Drive detected. Tap Mount to browse it."));
			}
		}

		// --- banner notifications on state transitions ---
		if (this.prevPresent !== null) {
			if (present && !this.prevPresent) { this.banner($L("USB drive detected")); }
			if (!present && this.prevPresent) { this.banner($L("USB drive removed")); }
			if (mounted && !this.prevMounted) {
				this.banner($L("USB drive mounted") + (st.mountpoint ? (" — " + st.mountpoint) : ""));
			}
			if (!mounted && this.prevMounted && present) { this.banner($L("USB drive unmounted")); }
		}
		this.prevPresent = present;
		this.prevMounted = mounted;

		this.updating = false;

		// operation finished -> hide the title spinner
		if (this.opInFlight) { this.opInFlight = false; this.$.titleSpinner.hide(); }

		if (!this.havePrefs) {
			this.havePrefs = true;
			this.$.spinner.hide();
			this.$.loadingView.setShowing(false);
			this.$.prefView.setShowing(true);
		}
	},

	handleSvcFail: function(inSender, r) {
		// service unreachable (not installed?) — surface the warning, stop spinners
		this.$.warnGroup.setShowing(true);
		if (this.opInFlight) { this.opInFlight = false; this.$.titleSpinner.hide(); }
		if (!this.havePrefs) {
			this.havePrefs = true;
			this.$.spinner.hide();
			this.$.loadingView.setShowing(false);
			this.$.prefView.setShowing(true);
		}
	},

	toggleOtg: function(inSender) {
		if (this.updating) { return; }
		this.startOp();
		this.$.send.call({command: inSender.getState() ? "otg-host" : "otg-peripheral"});
		window.setTimeout(enyo.bind(this, "refresh"), 800);
	},

	togglePower: function(inSender) {
		if (this.updating) { return; }
		this.startOp();
		this.$.send.call({command: inSender.getState() ? "power-on" : "power-off"});
		window.setTimeout(enyo.bind(this, "refresh"), 800);
	},

	toggleStorage: function(inSender) {
		if (this.$.storageBtnRow.getDisabled()) { return; }
		var mount = (this.$.storageBtnLabel.getContent() === $L("Mount"));
		this.startOp();
		this.$.send.call({command: mount ? "mount" : "unmount"});
		// mount/unmount can take a moment; refresh shortly to pick up the result
		window.setTimeout(enyo.bind(this, "refresh"), 1000);
	}
});
