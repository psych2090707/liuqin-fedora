// SPDX-License-Identifier: MIT
// GNOME Shell 51 rebuilds the entire OSK on every purpose/group notification.
// Keep only the CURRENT widget tree, never input text or a cache of old actors.
export function resolveModel(group, purpose, purposes, exists) {
    const fixed = new Map([
        [purposes.DIGITS, 'digits'], [purposes.NUMBER, 'number'],
        [purposes.PHONE, 'phone'], [purposes.EMAIL, 'email'],
        [purposes.URL, 'url'],
    ]);
    if (fixed.has(purpose))
        return fixed.get(purpose);
    const groups = [group];
    if (group.includes('+'))
        groups.push(group.replace(/\+.*/, ''));
    groups.push('us');
    const candidates = purpose === purposes.TERMINAL
        ? groups.map(name => `${name}-extended`) : groups;
    // Match the model-selection order of upstream keyboard.js. In particular
    // IBus's 'default' and the lock screen's 'us' both resolve to us.json.
    return candidates.find(exists) ?? `missing:${group}:${purpose}`;
}

export function layoutKey(group, purpose, purposes) {
    const textPurposes = [purposes.NORMAL, purposes.ALPHA, purposes.PASSWORD];
    // These three purposes take exactly the same model-selection branch and
    // all show the emoji key in upstream keyboard.js. All other purposes stay
    // separate, including TERMINAL, PIN, numeric, URL and email layouts.
    return JSON.stringify([group,
        textPurposes.includes(purpose) ? 'text-with-emoji' : purpose]);
}

export function installLayoutReuse({Keyboard, purposes,
    now, log, modelIdentity = group => group}) {
    const originalLayout = Keyboard.prototype._updateLayout;
    const currentLayouts = new WeakMap();

    Keyboard.prototype._updateLayout = function (group, purpose) {
        const key = layoutKey(modelIdentity(group, purpose), purpose, purposes);
        const previous = currentLayouts.get(this);
        if (previous?.key === key && previous.actor === this._currentLayout &&
            this._currentLayout && this._layers?.default) {
            // A lock boundary must not retain sticky modifiers, a held key,
            // delete repeat, suggestions, or the language menu. _updateKeys()
            // still runs stock _setActiveLevel('default') after this returns.
            this._disableAllModifiers();
            this._setLatched(false);
            this._keyboardController.toggleDelete(false);
            this._suggestions.clear();
            for (const button of this._currentPage?.get_children() ?? []) {
                button.cancel?.();
                button._hideSubkeys?.();
            }
            if (this._languagePopup) {
                this._languagePopup.destroy();
                this._languagePopup = null;
            }
            log(`reuse ${key}`);
            return;
        }

        currentLayouts.delete(this);
        const start = now();
        originalLayout.call(this, group, purpose);
        if (this._currentLayout && this._layers?.default)
            currentLayouts.set(this, {key, actor: this._currentLayout});
        log(`build ${key} ${(now() - start).toFixed(1)}ms`);
    };

    return () => {
        Keyboard.prototype._updateLayout = originalLayout;
    };
}
