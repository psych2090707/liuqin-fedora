// SPDX-License-Identifier: MIT
// The magnetic folio reports "laptop mode" while it is attached.  GNOME's
// stock OSK opens on every text focus whenever the accessibility OSK switch is
// on, even in laptop mode.  Keep those automatic opens out, but leave the
// bottom-edge swipe (the user explicitly asked for the native gesture) and
// an already visible keyboard alone.
export function shouldAllowOpen({touchMode, swipe, visible}) {
    if (visible)
        return true;
    return Boolean(touchMode || swipe);
}

export function coverAttached(touchMode) {
    return !touchMode;
}
