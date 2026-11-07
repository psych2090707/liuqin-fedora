// SPDX-License-Identifier: MIT
// Reuse the installed v4 layout/input/theme implementation, not another fork.
// The installer snapshots pinned v4 files here and keeps the old extension disabled.
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import * as KeyboardUI from 'resource:///org/gnome/shell/ui/keyboard.js';
import BaseLayout from './base-layout.js';
import {installLayoutReuse, resolveModel} from './layout-reuse.js';

export default class LiuqinTabletKeyboard extends BaseLayout {
    enable() {
        const models = new Map();
        this._restoreReuse = installLayoutReuse({
            Keyboard: KeyboardUI.Keyboard,
            purposes: Clutter.InputContentPurpose,
            modelIdentity: (group, purpose) => {
                const key = JSON.stringify([group, purpose]);
                if (!models.has(key)) {
                    models.set(key, resolveModel(group, purpose,
                        Clutter.InputContentPurpose, name => Gio.File.new_for_uri(
                            `resource:///org/gnome/shell/osk-layouts/${name}.json`
                        ).query_exists(null)));
                }
                return models.get(key);
            },
            now: () => GLib.get_monotonic_time() / 1000,
            log: message => console.log(`liuqin-osk-reuse: ${message}`),
        });
        try {
            super.enable();
        } catch (error) {
            this._restoreReuse();
            this._restoreReuse = null;
            throw error;
        }
    }

    disable() {
        // Restore before BaseLayout unregisters its resources and builds stock
        // keys, so no custom widget tree can survive disabling the extension.
        this._restoreReuse?.();
        this._restoreReuse = null;
        super.disable();
    }
}
