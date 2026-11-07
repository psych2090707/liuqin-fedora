// SPDX-License-Identifier: MIT
// Read the kernel's qcom-battmgr-pen power supply directly.  UPower is useful
// for other DEs, but reading sysfs avoids depending on its coldplug ordering.
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const SYSFS = '/sys/class/power_supply/qcom-battmgr-pen';
const POLL_SECONDS = 30;

function readAttr(name) {
    try {
        const file = Gio.File.new_for_path(`${SYSFS}/${name}`);
        const [, contents] = file.load_contents(null);
        return new TextDecoder().decode(contents).trim();
    } catch (_error) {
        return null;
    }
}

function levelClass(capacity) {
    if (capacity === null)
        return '';
    if (capacity <= 10)
        return 'critical';
    if (capacity <= 30)
        return 'low';
    return '';
}

const StylusIndicator = GObject.registerClass(
class StylusIndicator extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'Xiaomi Smart Pen');

        const box = new St.BoxLayout({
            style_class: 'panel-status-menu-box liuqin-stylus-box',
        });
        this._icon = new St.Icon({
            icon_name: 'document-edit-symbolic',
            style_class: 'system-status-icon',
        });
        this._bolt = new St.Label({
            text: '⚡',
            style_class: 'liuqin-stylus-bolt',
            y_align: Clutter.ActorAlign.CENTER,
            visible: false,
        });
        this._label = new St.Label({
            text: '',
            y_align: Clutter.ActorAlign.CENTER,
        });
        box.add_child(this._icon);
        box.add_child(this._bolt);
        box.add_child(this._label);
        this.add_child(box);

        const item = new PopupMenu.PopupBaseMenuItem({
            reactive: false,
            can_focus: false,
        });
        const card = new St.BoxLayout({
            orientation: Clutter.Orientation.VERTICAL,
            style_class: 'liuqin-stylus-card',
        });
        this._title = new St.Label({
            text: 'Xiaomi Smart Pen',
            style_class: 'liuqin-stylus-title',
        });
        this._status = new St.Label({
            text: '',
            style_class: 'liuqin-stylus-status',
        });
        this._track = new St.BoxLayout({
            style_class: 'liuqin-stylus-track',
        });
        this._fill = new St.Widget({
            style_class: 'liuqin-stylus-fill',
        });
        this._track.add_child(this._fill);
        card.add_child(this._title);
        card.add_child(this._status);
        card.add_child(this._track);
        item.add_child(card);
        this.menu.addMenuItem(item);

        this.visible = false;
    }

    refresh() {
        const present = readAttr('present');
        if (present !== '1') {
            this.visible = false;
            return;
        }

        const rawCapacity = readAttr('capacity');
        const capacity = rawCapacity !== null && /^\d+$/.test(rawCapacity)
            ? Number(rawCapacity)
            : null;
        const status = readAttr('status');
        const charging = status === 'Charging';
        const full = status === 'Full' || (capacity === 100 && !charging);

        let statusText;
        if (charging)
            statusText = '充电中';
        else if (full)
            statusText = '已充满';
        else if (status === 'Not charging')
            statusText = '未在充电（请调整位置）';
        else
            statusText = '未充电';

        const percentText = capacity === null ? '--' : `${capacity}%`;
        this._bolt.visible = charging;
        this._label.text = percentText;
        this._status.text = `${statusText} · ${percentText}`;
        this.visible = true;

        this._fill.remove_style_class_name('low');
        this._fill.remove_style_class_name('critical');
        const cls = levelClass(capacity);
        if (cls)
            this._fill.add_style_class_name(cls);
        this._fill.width = capacity === null
            ? 0
            : Math.max(2, Math.round(200 * capacity / 100));

        const tooltip = `Xiaomi Smart Pen: ${statusText} (${percentText})`;
        try {
            this.set_tooltip_text(tooltip);
        } catch (_error) {
            // Older St versions do not expose tooltip text on PanelMenu.Button.
        }
    }
});

export default class LiuqinStylusBattery extends Extension {
    enable() {
        this._indicator = new StylusIndicator();
        Main.panel.addToStatusArea('liuqin-stylus-battery', this._indicator);
        this._indicator.refresh();
        this._timeoutId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT, POLL_SECONDS, () => {
                this._indicator?.refresh();
                return GLib.SOURCE_CONTINUE;
            });
    }

    disable() {
        if (this._timeoutId) {
            GLib.source_remove(this._timeoutId);
            this._timeoutId = 0;
        }
        this._indicator?.destroy();
        this._indicator = null;
    }
}
