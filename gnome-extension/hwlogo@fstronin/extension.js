// SPDX-License-Identifier: GPL-2.0
//
// hwlogo@fstronin - Quick Settings control for the HUAWEI lid logo light.
//
// The tile drives the LED class device created by the hwlogo kernel module
// (/sys/class/leds/huawei::logo), so it needs no privileges beyond the udev
// rule shipped by the same package (group `plugdev`).
//
// Notes for whoever ports this to another shell version:
//   * QuickToggle/SystemIndicator live in ui/quickSettings.js and have been
//     stable since GNOME 45; `addExternalIndicator()` is a method of the
//     Quick Settings panel button (Main.panel.statusArea.quickSettings).
//   * The LED core applies brightness asynchronously (~200 ms), hence the
//     delayed re-read after a click and the periodic poll.

import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {QuickToggle, SystemIndicator} from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const LED_PATH = '/sys/class/leds/huawei::logo/brightness';
const POLL_SECONDS = 2;
const SETTLE_MS = 300;
const ICON_NAME = 'hwlogo-symbolic';
const FALLBACK_ICON = 'display-brightness-symbolic';
// A symbolic icon is picked up by name only when it sits in an icon theme
// search path, so the package installs it as a hicolor icon; St.IconTheme
// has no get_default() in GNOME 50, hence the plain file checks.
const ICON_LOCATIONS = [
    '/usr/share/icons/hicolor/symbolic/apps/hwlogo-symbolic.svg',
    'icons/hicolor/symbolic/apps/hwlogo-symbolic.svg',   // below the user data dir
];
const decoder = new TextDecoder();
const encoder = new TextEncoder();

/** @returns {boolean|null} true = light on, false = off, null = device missing */
function readState() {
    try {
        const [, bytes] = GLib.file_get_contents(LED_PATH);
        return decoder.decode(bytes).trim() !== '0';
    } catch {
        return null; // hwlogo module not loaded
    }
}

/** @returns {boolean} whether the write was accepted */
function writeState(on) {
    try {
        // note: GFile.replace_contents()/GLib.file_set_contents() do not work
        // on sysfs attributes - they write through a temporary file
        const stream = Gio.File.new_for_path(LED_PATH).open_readwrite(null);
        try {
            stream.get_output_stream().write_all(encoder.encode(on ? '1' : '0'), null);
        } finally {
            stream.close(null);
        }
        return true;
    } catch (e) {
        console.error(`hwlogo: cannot write ${LED_PATH}: ${e.message}`);
        return false;
    }
}

const LogoLightToggle = GObject.registerClass(
class LogoLightToggle extends QuickToggle {
    _init(iconName) {
        super._init({
            title: 'Logo light',
            iconName,
            toggleMode: false,
        });

        this.connect('clicked', () => {
            const state = readState();
            if (state === null)
                return;
            if (!writeState(!state))
                return;

            this.checked = !state;
            this._scheduleSync();
        });

        this.sync();
    }

    _scheduleSync() {
        if (this._syncId)
            GLib.source_remove(this._syncId);
        this._syncId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, SETTLE_MS, () => {
            this._syncId = 0;
            this.sync();
            return GLib.SOURCE_REMOVE;
        });
    }

    /** Re-read the hardware state (it may have been changed by hwlogo(1)). */
    sync() {
        const state = readState();
        this.reactive = state !== null;
        this.checked = state === true;
    }

    destroy() {
        if (this._syncId) {
            GLib.source_remove(this._syncId);
            this._syncId = 0;
        }
        super.destroy();
    }
});

const LogoLightIndicator = GObject.registerClass(
class LogoLightIndicator extends SystemIndicator {
    _init(iconName) {
        super._init();

        // small icon in the top bar, visible while the logo light is on
        this._icon = this._addIndicator();
        this._icon.iconName = iconName;

        this._toggle = new LogoLightToggle(iconName);
        this._toggle.bind_property('checked', this._icon, 'visible',
            GObject.BindingFlags.SYNC_CREATE | GObject.BindingFlags.BIDIRECTIONAL);
        this.quickSettingsItems.push(this._toggle);

        this._pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, POLL_SECONDS, () => {
            this._toggle.sync();
            return GLib.SOURCE_CONTINUE;
        });
    }

    destroy() {
        if (this._pollId) {
            GLib.source_remove(this._pollId);
            this._pollId = 0;
        }
        this.quickSettingsItems.forEach(item => item.destroy());
        super.destroy();
    }
});

export default class HwLogoLightExtension extends Extension {
    enable() {
        this._indicator = new LogoLightIndicator(this._iconName());
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }

    /** Use our own symbolic icon when installed, a stock one otherwise. */
    _iconName() {
        for (const location of ICON_LOCATIONS) {
            const path = GLib.path_is_absolute(location)
                ? location
                : GLib.build_filenamev([GLib.get_user_data_dir(), location]);
            try {
                if (Gio.File.new_for_path(path).query_exists(null))
                    return ICON_NAME;
            } catch {
                // ignore and try the next location
            }
        }
        console.debug(`hwlogo: ${ICON_NAME} not installed, using ${FALLBACK_ICON}`);
        return FALLBACK_ICON;
    }
}
