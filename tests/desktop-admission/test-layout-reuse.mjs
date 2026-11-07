// Run with: node tests/desktop-admission/test-layout-reuse.mjs
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const source = readFileSync(new URL('../../overlays/gnome-local/keyboard/extension/layout-reuse.js', import.meta.url));
const {installLayoutReuse, layoutKey, resolveModel} = await import(
    `data:text/javascript;base64,${source.toString('base64')}`);

const purposes = {NORMAL: 0, ALPHA: 1, DIGITS: 2, NUMBER: 3, PHONE: 4,
    URL: 5, EMAIL: 6, NAME: 7, PASSWORD: 8, PIN: 9, TERMINAL: 10};
class Keyboard {
    constructor() {
        this.builds = 0;
        this.resets = 0;
        this.popoversClosed = 0;
        this._currentPage = {get_children: () => [{cancel: () => this.resets++,
            _hideSubkeys: () => this.popoversClosed++}]};
        this._keyboardController = {toggleDelete: x => assert.equal(x, false)};
        this._suggestions = {clear: () => this.resets++};
    }
    _updateLayout() {
        this.builds++;
        this._currentLayout = {};
        this._layers = {default: {}};
    }
    _disableAllModifiers() { this.resets++; }
    _setLatched(x) { assert.equal(x, false); this.resets++; }
}
class KeyboardManager {
    maybeHandleEvent() { return 'stock'; }
}
const originalLayout = Keyboard.prototype._updateLayout;
const originalEvent = KeyboardManager.prototype.maybeHandleEvent;
let clock = 0;
const logs = [];
const models = new Set(['us', 'us-extended', 'de', 'de-extended']);
const modelIdentity = (group, purpose) => resolveModel(group, purpose, purposes,
    name => models.has(name));
const restore = installLayoutReuse({Keyboard, KeyboardManager, purposes,
    eventActor: event => event.actor, now: () => clock++, log: x => logs.push(x),
    modelIdentity});
const keyboard = new Keyboard();
keyboard._updateLayout('us', purposes.NORMAL);
keyboard._updateLayout('us', purposes.PASSWORD);
keyboard._updateLayout('us', purposes.ALPHA);
keyboard._updateLayout('us', purposes.NORMAL);
assert.equal(keyboard.builds, 1, 'text/password notifications reuse current keys');
assert.equal(keyboard.resets, 12, 'reuse clears transient key and suggestion state');
assert.equal(keyboard.popoversClosed, 3, 'extended key popovers closed before reuse');
keyboard._updateLayout('default', purposes.PASSWORD);
keyboard._updateLayout('us', purposes.NORMAL);
assert.equal(keyboard.builds, 1, 'IBus default and lock-screen us resolve to same model');
assert.equal(modelIdentity('de+nodeadkeys', purposes.NORMAL), 'de');
assert.equal(modelIdentity('default', purposes.TERMINAL), 'us-extended');
assert.equal(modelIdentity('us', purposes.DIGITS), 'digits');
keyboard._updateLayout('us', purposes.PIN);
keyboard._updateLayout('us', purposes.TERMINAL);
keyboard._updateLayout('us', purposes.EMAIL);
keyboard._updateLayout('us', purposes.URL);
keyboard._updateLayout('de', purposes.NORMAL);
assert.equal(keyboard.builds, 6, 'special purposes and other groups rebuild');
keyboard._updateLayout('us', purposes.NORMAL);
assert.equal(keyboard.builds, 7, 'only current tree is retained');
keyboard._currentLayout = {};
keyboard._updateLayout('us', purposes.NORMAL);
assert.equal(keyboard.builds, 8, 'external layout replacement invalidates reuse');
const second = new Keyboard();
second._updateLayout('us', purposes.NORMAL);
assert.equal(second.builds, 1, 'new keyboard never inherits another actor cache');
keyboard._languagePopup = {destroy: () => keyboard.resets++};
keyboard._updateLayout('us', purposes.PASSWORD);
assert.equal(keyboard._languagePopup, null, 'language popup closed at boundary');
const manager = new KeyboardManager();
assert.equal(manager.maybeHandleEvent({actor: null}), false);
assert.equal(manager.maybeHandleEvent({actor: {}}), 'stock');
assert.notEqual(layoutKey('us', purposes.PIN, purposes),
    layoutKey('us', purposes.PASSWORD, purposes));
restore();
assert.equal(Keyboard.prototype._updateLayout, originalLayout);
assert.equal(KeyboardManager.prototype.maybeHandleEvent, originalEvent);
assert.ok(logs.some(x => x.startsWith('build')));
assert.ok(logs.some(x => x.startsWith('reuse')));
console.log('PASS: layout reuse, special-purpose isolation, state reset, null event and teardown');
