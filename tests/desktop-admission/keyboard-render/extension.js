import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import IBus from 'gi://IBus';
import Shell from 'gi://Shell';

import * as IBusManager from 'resource:///org/gnome/shell/misc/ibusManager.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const OUT = GLib.getenv('KBINT_OUT') ?? '/tmp/opencode/kbint/out.png';
const TEXT = GLib.getenv('KBINT_TEXT') ?? 'ni hao |';
const MODE = GLib.getenv('KBINT_MODE') ?? 'osk';
const log = m => console.log(`kbint: ${m}`);

const FakeText = GObject.registerClass(class FakeText extends GObject.Object {
    constructor(text) {
        super();
        this._text = text;
    }
    get_text() { return this._text; }
    get_attributes() { return {get: () => null}; }
});

const FakeLookup = GObject.registerClass(class FakeLookup extends GObject.Object {
    constructor(cursor = 0) {
        super();
        this._cursor = cursor;
    }
    get_number_of_candidates() { return 5; }
    get_cursor_pos() { return this._cursor; }
    get_page_size() { return 5; }
    get_label(i) {
        return i < 5 ? {get_text: () => String(i + 1)} : null;
    }
    get_candidate(i) {
        return {get_text: () => ['你好', '你好吗', '你', '尼', '呢'][i]};
    }
    is_cursor_visible() { return true; }
    get_orientation() { return IBus.Orientation.HORIZONTAL; }
    is_round() { return true; }
});

const FakePanel = GObject.registerClass({
    Signals: {
        'set-cursor-location': {param_types: [GObject.TYPE_INT, GObject.TYPE_INT,
            GObject.TYPE_INT, GObject.TYPE_INT]},
        'set-cursor-location-relative': {param_types: [GObject.TYPE_INT, GObject.TYPE_INT,
            GObject.TYPE_INT, GObject.TYPE_INT]},
        'update-preedit-text': {param_types: [GObject.TYPE_OBJECT, GObject.TYPE_UINT,
            GObject.TYPE_BOOLEAN]},
        'show-preedit-text': {},
        'hide-preedit-text': {},
        'update-auxiliary-text': {param_types: [GObject.TYPE_OBJECT, GObject.TYPE_BOOLEAN]},
        'show-auxiliary-text': {},
        'hide-auxiliary-text': {},
        'update-lookup-table': {param_types: [GObject.TYPE_OBJECT, GObject.TYPE_BOOLEAN]},
        'show-lookup-table': {},
        'hide-lookup-table': {},
        'focus-out': {},
    },
}, class FakePanel extends GObject.Object {});

function findClass(root, name) {
    if (root.has_style_class_name?.(name))
        return root;
    for (const child of root.get_children?.() ?? []) {
        const found = findClass(child, name);
        if (found)
            return found;
    }
    return null;
}

export default class extends Extension {
    enable() {
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 4, () => {
            if (MODE === 'popup')
                this._popupTest();
            else
                this._open();
            return GLib.SOURCE_REMOVE;
        });
    }

    _popupTest() {
        try {
            const manager = IBusManager.getIBusManager();
            const popup = manager._candidatePopup;
            if (!popup) {
                log('FAIL no candidate popup');
                this._quit();
                return;
            }
            this._panel = new FakePanel();
            popup.setPanelService(this._panel);
            // Simulate the real-world case where the panel service hides its
            // preedit: the shell's client-side preedit must still feed the
            // physical-keyboard bubble.  Call the real InputMethod handler so
            // the extension's client-preedit hook is exercised.
            Main.inputMethod._onUpdatePreeditText(null, new FakeText(TEXT), 0, true, 0);
            this._panel.emit('hide-preedit-text');
            this._panel.emit('update-lookup-table', new FakeLookup(0), true);
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 600, () => {
                const label = popup._preeditText;
                log(`popup=${popup.visible} preedit=${label?.visible} text=${JSON.stringify(label?.text ?? '')}`);
                if (!popup.visible || !label?.visible ||
                    label.text !== TEXT.replace(/\s*\|\s*$/, '').trim())
                    log('FAIL popup preedit');
                this._shot();
                return GLib.SOURCE_REMOVE;
            });
        } catch (e) {
            log(`FAIL popup ${e}\n${e.stack}`);
            this._quit();
        }
    }

    disable() {}

    _open() {
        try {
            const kb = Main.keyboard?.keyboardActor;
            if (!kb) {
                log('FAIL no keyboard actor');
                this._quit();
                return;
            }
            kb.gestureActivate();
            log(`opened=${kb.visible} size=${kb.width}x${kb.height}`);
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 700, () => {
                this._inject();
                return GLib.SOURCE_REMOVE;
            });
        } catch (e) {
            log(`FAIL open ${e}\n${e.stack}`);
            this._quit();
        }
    }

    _inject() {
        try {
            const manager = IBusManager.getIBusManager();
            const popup = manager._candidatePopup;
            if (!popup) {
                log('FAIL no candidate popup');
                this._quit();
                return;
            }
            this._panel = new FakePanel();
            popup.setPanelService(this._panel);
            this._panel.emit('update-preedit-text', new FakeText(TEXT), 0, true);
            this._panel.emit('update-lookup-table', new FakeLookup(), true);
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 600, () => {
                this._verify();
                return GLib.SOURCE_REMOVE;
            });
        } catch (e) {
            log(`FAIL inject ${e}\n${e.stack}`);
            this._quit();
        }
    }

    _verify() {
        try {
            const kb = Main.keyboard?.keyboardActor;
            if (!kb) {
                log('FAIL keyboard vanished');
                this._quit();
                return;
            }
            const chip = findClass(kb, 'liuqin-osk-preedit');
            const chipText = chip?.get_children?.()[0]?.text ?? '';
            log(`chip=${Boolean(chip?.visible)} text=${JSON.stringify(chipText)}`);

            const suggestions = kb._suggestions;
            const children = suggestions.get_children();
            const selected = children.findIndex(c =>
                c.has_style_class_name('liuqin-candidate-selected'));
            log(`suggestions=${children.length} selected=${selected} align=${suggestions.x_align}`);

            let pills = 0;
            let hideIcon = '';
            for (const button of kb._currentPage.get_children()) {
                const key = button._liuqinDescriptor;
                if (button.keyButton.has_style_class_name('liuqin-key-pill'))
                    pills++;
                if (key?.label === 'Fn')
                    log(`fn=${key.label}`);
                const hide = findClass(button, 'liuqin-osk-hide');
                if (hide)
                    hideIcon = hide.child?.icon_name ?? '';
            }
            const hide = findClass(kb, 'liuqin-osk-hide');
            hideIcon = hide?.child?.icon_name ?? hideIcon;
            log(`pills=${pills} hideIcon=${hideIcon}`);

            if (!chip?.visible || chipText !== TEXT.replace(/\s*\|\s*$/, '').trim())
                log('FAIL preedit chip');
            if (selected !== 0)
                log('FAIL selected candidate');
            if (pills < 5)
                log('FAIL pill classes');
            if (hideIcon !== 'osk-hide-symbolic')
                log('FAIL hide icon');
            log('checks done');
            this._shot();
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
                this._phase2();
                return GLib.SOURCE_REMOVE;
            });
        } catch (e) {
            log(`FAIL verify ${e}\n${e.stack}`);
            this._quit();
        }
    }

    _phase2() {
        try {
            this._panel.emit('update-lookup-table', new FakeLookup(2), true);
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, () => {
                const children = Main.keyboard.keyboardActor._suggestions.get_children();
                const selected = children.findIndex(c =>
                    c.has_style_class_name('liuqin-candidate-selected'));
                log(`phase2 selected=${selected}`);
                if (selected !== 2)
                    log('FAIL selected cursor 2');
                this._phase3();
                return GLib.SOURCE_REMOVE;
            });
        } catch (e) {
            log(`FAIL phase2 ${e}\n${e.stack}`);
            this._quit();
        }
    }

    _phase3() {
        try {
            this._panel.emit('hide-preedit-text');
            this._panel.emit('update-auxiliary-text', new FakeText('ni hao |'), true);
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, () => {
                const chip = findClass(Main.keyboard.keyboardActor, 'liuqin-osk-preedit');
                const text = chip?.get_children?.()[0]?.text ?? '';
                log(`phase3 aux chip=${Boolean(chip?.visible)} text=${JSON.stringify(text)}`);
                if (!chip?.visible || text !== 'ni hao')
                    log('FAIL auxiliary chip');
                this._panel.emit('hide-auxiliary-text');
                GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, () => {
                    const again = findClass(Main.keyboard.keyboardActor, 'liuqin-osk-preedit');
                    log(`phase3 hidden=${!again?.visible}`);
                    if (again?.visible)
                        log('FAIL chip did not hide');
                    this._quit();
                    return GLib.SOURCE_REMOVE;
                });
                return GLib.SOURCE_REMOVE;
            });
        } catch (e) {
            log(`FAIL phase3 ${e}\n${e.stack}`);
            this._quit();
        }
    }

    async _shot() {
        try {
            const stream = Gio.File.new_for_path(OUT).replace(null, false,
                Gio.FileCreateFlags.NONE, null);
            const shot = new Shell.Screenshot();
            if (GLib.getenv('KBINT_BOUNDS') === 'keyboard') {
                const actor = Main.keyboard.keyboardActor;
                const [x, y] = actor.get_transformed_position();
                const [width, height] = actor.get_transformed_size();
                log(`capture=${Math.floor(x)},${Math.floor(y)},${Math.ceil(width)},${Math.ceil(height)}`);
                await shot.screenshot_area(Math.floor(x), Math.floor(y),
                    Math.ceil(width), Math.ceil(height), stream);
            } else {
                await shot.screenshot(false, stream);
            }
            stream.close(null);
            log(`saved ${OUT}`);
        } catch (e) {
            log(`FAIL shot ${e}\n${e.stack}`);
            this._quit();
        }
    }

    _quit() {
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 800, () => {
            global.context.terminate();
            return GLib.SOURCE_REMOVE;
        });
    }
}
