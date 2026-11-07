/* liuqin-osk-layout@liuqin — tablet on-screen-keyboard layout for GNOME Shell 51.
 *
 * Installed system-wide on the Xiaomi Pad 6 Pro (liuqin).
 * It does two independent, reversible things while enabled:
 *
 * 1. Layout/size: registers a small GResource that overrides
 *    /org/gnome/shell/osk-layouts/us.json (and us-extended.json) with a
 *    selected 5-row, 15-column proposal A (number row + Fn/navigation layer), and
 *    raises the OSK height from 1/3 to 45 % of the monitor height so the
 *    keyboard is wider and the keys bigger.  The stock gnome-shell resource
 *    stays untouched on disk; later-registered resources win lookups, and this
 *    registration is removed again in disable().
 *
 * 2. The old GNOME 50 language-menu workaround was removed for GNOME 51:
 *    upstream keyboard.js now calls the correct BoxPointer.PopupAnimation
 *    constant, so keeping a private popup replacement would only add another
 *    private-API dependency.
 *
 * disable() restores the stock methods and unregisters the resource.  Every entry
 * point is guarded: a failure is logged and never propagated into the shell.
 */

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as KeyboardUI from 'resource:///org/gnome/shell/ui/keyboard.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import {sendShortcut} from './shortcuts.js';

const LOG_PREFIX = 'liuqin-osk-layout';
const HEIGHT_FRACTION = 0.45;
const LAYOUT_RESOURCE = 'resource:///org/gnome/shell/osk-layouts/us.json';

function logMsg(message) {
    console.log(`${LOG_PREFIX}: ${message}`);
}

export default class LiuqinOskLayoutExtension extends Extension {
    enable() {
        this._resource = null;
        this._origRelayout = null;
        this._origOpen = null;
        this._needsRebuild = false;
        this._layoutOriginals = new Map();
        this._actors = new Map();

        this._registerLayoutResource();
        this._patchLayouts();
        this._patchRelayout();
        this._patchOpen();
        this._verifyLayoutResource();
        this._rebuildKeyboard('enable');
    }

    disable() {
        this._restoreOpen();
        this._restoreRelayout();
        for (const [method, original] of this._layoutOriginals)
            KeyboardUI.Keyboard.prototype[method] = original;
        this._layoutOriginals.clear();
        for (const actor of [...this._actors.keys()])
            this._restoreActors(actor);

        if (this._resource) {
            try {
                Gio.resources_unregister(this._resource);
                logMsg('layout resource unregistered');
            } catch (e) {
                logError(e, `${LOG_PREFIX}: unregistering layout resource`);
            }
            this._resource = null;
        }

        try {
            this._rebuildKeyboard('disable');
        } catch (e) {
            logError(e, `${LOG_PREFIX}: restoring stock keyboard on disable`);
        }
    }

    // ------------------------------------------------------------- layout --

    _patchLayouts() {
        const extension = this;
        const patch = (name, wrapper) => {
            const original = KeyboardUI.Keyboard.prototype[name];
            this._layoutOriginals.set(name, original);
            KeyboardUI.Keyboard.prototype[name] = wrapper(original);
        };
        patch('_addRowKeys', original => function (keys, layout, emojiVisible) {
            if (!keys.some(key => key.liuqin))
                return original.call(this, keys, layout, emojiVisible);

            layout._liuqinLayout = true;
            // Stock GNOME mutates strings and widths; preserve our descriptors.
            const descriptors = keys.map(key => ({...key,
                strings: key.strings ? [...key.strings] : undefined}));
            const prepared = descriptors.map(key => ({...key,
                strings: key.strings ? [...key.strings] : undefined,
                // Stock's action branch deliberately leaves these custom
                // signals unconnected. Wire them below, without double sends.
                action: key.action === 'delete' ? 'liuqinDelete' :
                    (!key.action && key.keyval ? 'liuqinKeyval' :
                        (!key.action && key.strings ? 'liuqinCommit' : key.action)),
            }));
            const before = layout.get_children().length;
            original.call(this, prepared, layout, emojiVisible);
            const buttons = layout.get_children().slice(before);
            const visible = descriptors.filter(key => emojiVisible || key.action !== 'emoji');
            buttons.forEach((button, index) => {
                const key = visible[index];
                button._liuqinDescriptor = key;
                if (!key.action && key.keyval) {
                    button.connect('keyval', (_button, keyval) =>
                        extension._sendRaw(this, keyval));
                } else if (!key.action && key.strings) {
                    button.keyButton.remove_style_class_name('default-key');
                    button.connect('commit', (_button, str) =>
                        extension._commit(this, str));
                } else if (key.action === 'delete') {
                    let deleting = false;
                    button.connect('released', () => {
                        if (deleting) {
                            this._keyboardController.toggleDelete(false);
                            deleting = false;
                            this._updateLevelFromHints(true);
                        } else if (this._modifiers.size > 0)
                            extension._sendRaw(this, Clutter.KEY_BackSpace);
                        else {
                            this._keyboardController.toggleDelete(true);
                            this._keyboardController.toggleDelete(false);
                            this._updateLevelFromHints(true);
                        }
                    });
                    button.connect('long-press', () => {
                        if (this._modifiers.size === 0) {
                            deleting = true;
                            this._keyboardController.toggleDelete(true);
                        }
                    });
                }
                if (key.liuqinShift) {
                    const label = new St.Widget({layout_manager: new Clutter.BinLayout(),
                        style_class: 'liuqin-key-label', x_expand: true, y_expand: true});
                    // BinLayout ignores a child's alignment unless that child
                    // needs expansion; expanding only the parent centers both.
                    label.add_child(new St.Label({text: key.label ?? key.strings[0],
                        x_expand: true, y_expand: true,
                        x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER}));
                    label.add_child(new St.Label({text: key.liuqinShift,
                        style_class: 'liuqin-key-secondary',
                        x_expand: true, y_expand: true,
                        x_align: Clutter.ActorAlign.END, y_align: Clutter.ActorAlign.START}));
                    button.keyButton.set_child(label);
                }
            });
        });
        patch('_setActiveLevel', original => function (level) {
            const preserve = this._currentPage?._liuqinLayout && this._layers[level]?._liuqinLayout;
            const modifiers = preserve ? [...this._modifiers] : [];
            original.call(this, level);
            this._liuqinLevel = this._currentPage?._liuqinLayout ? level : null;
            for (const modifier of modifiers)
                this._setModifierEnabled(modifier, true);
            if (this._liuqinLevel) {
                extension._ensureActors(this);
                for (const button of this._currentPage.get_children()) {
                    const key = button._liuqinDescriptor;
                    if (key?.label === 'Fn')
                        button.setLatched(level.startsWith('opt'));
                    else if (key?.label === 'Caps')
                        button.setLatched(level.startsWith('caps'));
                    else if (key?.label === 'Shift')
                        button.setLatched(level.includes('shift'));
                }
            } else {
                extension._restoreActors(this);
            }
        });
        patch('_updateLevelFromHints', original => function (userInputHappened) {
            const level = this._liuqinLevel;
            if (level && userInputHappened && level.includes('shift') && !this._latched) {
                this._setActiveLevel(level === 'shift' ? 'default' : level.replace('+shift', ''));
                return;
            }
            if (level?.startsWith('caps') || level?.startsWith('opt'))
                return;
            return original.call(this, userInputHappened);
        });
        patch('_setLatched', original => function (latched) {
            original.call(this, latched);
            if (this._liuqinLevel?.includes('shift')) {
                for (const button of this._currentPage.shiftKeys)
                    button.setLatched(true);
            }
        });
        patch('close', original => function (...args) {
            if (this._liuqinLevel) {
                this._disableAllModifiers();
                this._keyboardController.toggleDelete(false);
            }
            return original.apply(this, args);
        });
    }

    _takeModifiers(actor) {
        const modifiers = new Set([...actor._modifiers].map(Number));
        if (actor._liuqinLevel?.includes('shift'))
            modifiers.add(Clutter.KEY_Shift_L);
        actor._disableAllModifiers();
        return modifiers;
    }

    _sendRaw(actor, keyval) {
        try {
            sendShortcut(actor._keyboardController, keyval, this._takeModifiers(actor));
            actor._updateLevelFromHints(true);
        } catch (e) {
            logError(e, `${LOG_PREFIX}: keyval`);
        }
    }

    async _commit(actor, str) {
        const hasModifiers = actor._modifiers.size > 0;
        const controller = actor._keyboardController;
        const page = actor._currentPage;
        const modifiers = this._takeModifiers(actor);
        try {
            if (hasModifiers) {
                // Use base letter + explicit Shift for Ctrl+Shift+C, rather
                // than relying on uppercase-keyval implicit modifier mapping.
                const value = /^[a-z]$/i.test(str) ? str.toLowerCase() : str;
                for (const character of value)
                    sendShortcut(controller, Clutter.unicode_to_keysym(character.codePointAt(0)), modifiers);
            } else {
                // Ordinary text must still pass through the existing IBus
                // virtual-key path. Do not replace Chinese with raw injection.
                await controller.commit(str, new Set());
            }
            if (actor._currentPage === page)
                actor._updateLevelFromHints(true);
        } catch (e) {
            logError(e, `${LOG_PREFIX}: commit`);
        }
    }

    _ensureActors(actor) {
        if (this._actors.has(actor))
            return;
        const originalAspect = actor._aspectContainer;
        const originalExpand = actor._suggestions.x_expand;
        const stretch = new St.Widget({layout_manager: new Clutter.BinLayout(),
            x_expand: true, y_expand: true});
        // Native code calls setRatio on every layer switch. A normal widget
        // needs no ratio: rectangular keys intentionally fill the whole width.
        stretch.setRatio = () => {};
        for (const child of originalAspect.get_children()) {
            originalAspect.remove_child(child);
            stretch.add_child(child);
        }
        const aspectIndex = actor.get_children().indexOf(originalAspect);
        actor.remove_child(originalAspect);
        actor.insert_child_at_index(stretch, aspectIndex);
        actor._aspectContainer = stretch;
        actor.remove_child(actor._suggestions);
        actor._suggestions.x_expand = true;
        const header = new St.BoxLayout({style_class: 'liuqin-osk-header', x_expand: true});
        header.add_child(actor._suggestions);
        const hide = new St.Button({label: '收起', style_class: 'liuqin-osk-hide',
            can_focus: false, reactive: true});
        hide.connect('clicked', () => actor.close(true));
        header.add_child(hide);
        actor.insert_child_at_index(header, 0);
        actor.add_style_class_name('liuqin-osk-a');
        const destroyId = actor.connect('destroy', () => {
            originalAspect.destroy();
            this._actors.delete(actor);
        });
        this._actors.set(actor, {originalAspect, originalExpand, stretch, header, destroyId});
    }

    _restoreActors(actor) {
        const record = this._actors.get(actor);
        if (!record)
            return;
        const {originalAspect, originalExpand, stretch, header, destroyId} = record;
        actor.disconnect(destroyId);
        header.remove_child(actor._suggestions);
        actor._suggestions.x_expand = originalExpand;
        actor.remove_child(header);
        header.destroy();
        actor.insert_child_at_index(actor._suggestions, 0);
        for (const child of stretch.get_children()) {
            stretch.remove_child(child);
            originalAspect.add_child(child);
        }
        const index = actor.get_children().indexOf(stretch);
        actor.remove_child(stretch);
        actor.insert_child_at_index(originalAspect, index);
        actor._aspectContainer = originalAspect;
        stretch.destroy();
        if (actor._currentPage)
            originalAspect.setRatio(...actor._currentPage.getRatio());
        actor.remove_style_class_name('liuqin-osk-a');
        this._actors.delete(actor);
    }

    _registerLayoutResource() {
        try {
            const path = this.dir.get_child('osk-layouts.gresource').get_path();
            const resource = Gio.Resource.load(path);
            Gio.resources_register(resource);
            this._resource = resource;
            logMsg(`layout resource registered: ${path}`);
        } catch (e) {
            logError(e, `${LOG_PREFIX}: cannot register layout resource; keeping stock OSK`);
            this._resource = null;
        }
    }

    _verifyLayoutResource() {
        try {
            const file = Gio.File.new_for_uri(LAYOUT_RESOURCE);
            const [, contents] = file.load_contents(null);
            const checksum = GLib.compute_checksum_for_data(
                GLib.ChecksumType.SHA256, contents);
            let expected = null;
            try {
                const [, raw] = this.dir.get_child('expected.sha256').load_contents(null);
                expected = new TextDecoder().decode(raw).trim().split(/\s+/)[0];
            } catch (e) {
                logMsg('expected.sha256 missing, only logging the checksum');
            }
            if (expected && expected !== checksum)
                logMsg(`WARNING us.json sha256 ${checksum}, expected ${expected}`);
            else
                logMsg(`us.json sha256 ${checksum}${expected ? ' (matches expected.sha256)' : ''}`);
        } catch (e) {
            logError(e, `${LOG_PREFIX}: cannot verify layout resource`);
        }
    }

    _patchRelayout() {
        try {
            this._origRelayout = KeyboardUI.Keyboard.prototype._relayout;
            const original = this._origRelayout;
            KeyboardUI.Keyboard.prototype._relayout = function () {
                try {
                    original.call(this);
                    const monitor = Main.layoutManager.keyboardMonitor;
                    if (monitor) {
                        const target = monitor.height * HEIGHT_FRACTION;
                        this.height = Math.min(Math.max(this.height, target),
                            monitor.height / 2);
                    }
                } catch (e) {
                    logError(e, `${LOG_PREFIX}: relayout override`);
                }
            };
            logMsg('Keyboard._relayout patched');
        } catch (e) {
            logError(e, `${LOG_PREFIX}: cannot patch _relayout`);
            this._origRelayout = null;
        }
    }

    _restoreRelayout() {
        if (!this._origRelayout)
            return;
        try {
            KeyboardUI.Keyboard.prototype._relayout = this._origRelayout;
            logMsg('Keyboard._relayout restored');
        } catch (e) {
            logError(e, `${LOG_PREFIX}: restoring _relayout`);
        }
        this._origRelayout = null;
    }

    // --------------------------------------------------------- rebuild glue --

    _patchOpen() {
        try {
            this._origOpen = KeyboardUI.Keyboard.prototype._open;
            const original = this._origOpen;
            const extension = this;
            KeyboardUI.Keyboard.prototype._open = function () {
                try {
                    if (extension._needsRebuild)
                        extension._rebuildKeyboard('deferred');
                } catch (e) {
                    logError(e, `${LOG_PREFIX}: deferred keyboard rebuild`);
                }
                return original.call(this);
            };
        } catch (e) {
            logError(e, `${LOG_PREFIX}: cannot patch _open`);
            this._origOpen = null;
        }
    }

    _restoreOpen() {
        if (!this._origOpen)
            return;
        try {
            KeyboardUI.Keyboard.prototype._open = this._origOpen;
        } catch (e) {
            logError(e, `${LOG_PREFIX}: restoring _open`);
        }
        this._origOpen = null;
    }

    _rebuildKeyboard(reason) {
        try {
            const manager = Main.keyboard;
            const actor = manager ? manager.keyboardActor : null;
            if (!actor) {
                this._needsRebuild = true;
                logMsg(`no OSK actor yet, rebuild deferred (${reason})`);
                return;
            }

            this._needsRebuild = false;
            actor._updateKeys();
            actor._relayout();
            const monitor = Main.layoutManager.keyboardMonitor;
            const monitorSize = monitor ? `${monitor.width}x${monitor.height}` : 'unknown';
            logMsg(`OSK rebuilt with liuqin layout (${reason}), ` +
                `monitor ${monitorSize}, actor ${actor.width}x${actor.height}`);
        } catch (e) {
            this._needsRebuild = true;
            logError(e, `${LOG_PREFIX}: rebuilding OSK (${reason})`);
        }
    }
}
