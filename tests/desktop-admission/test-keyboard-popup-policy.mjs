// Run with: node tests/desktop-admission/test-keyboard-popup-policy.mjs
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const source = readFileSync(new URL(
    '../../overlays/gnome-local/keyboard/extension/popup-policy.js',
    import.meta.url));
const {shouldAllowOpen, coverAttached} = await import(
    `data:text/javascript;base64,${source.toString('base64')}`);

assert.equal(shouldAllowOpen({touchMode: true, swipe: false, visible: false}), true,
    'no cover: tapping a text field opens the OSK');
assert.equal(shouldAllowOpen({touchMode: false, swipe: false, visible: false}), false,
    'cover attached: focus/open requests are suppressed');
assert.equal(shouldAllowOpen({touchMode: false, swipe: true, visible: false}), true,
    'cover attached: an explicit bottom-edge swipe still opens the OSK');
assert.equal(shouldAllowOpen({touchMode: false, swipe: false, visible: true}), true,
    'cover attached: an already visible OSK stays open');
assert.equal(shouldAllowOpen({touchMode: true, swipe: false, visible: true}), true,
    'no cover: an already visible OSK stays open');
assert.equal(coverAttached(false), true);
assert.equal(coverAttached(true), false);
console.log('PASS: cover-aware OSK popup policy');
