// Pure event sequencing; no devices are created here. The controller is the
// existing GNOME KeyboardController (tests supply an in-memory recorder).
export function sendShortcut(controller, keyval, modifiers) {
    const pressed = [];
    let keyPressed = false;
    try {
        for (const modifier of modifiers) {
            // Track before calling: even a partially failed press gets released.
            pressed.push(Number(modifier));
            controller.keyvalPress(Number(modifier));
        }
        keyPressed = true;
        controller.keyvalPress(keyval);
        controller.keyvalRelease(keyval);
        keyPressed = false;
    } finally {
        // Release everything even if one of the controller calls throws.
        let releaseError = null;
        if (keyPressed) {
            try { controller.keyvalRelease(keyval); } catch (e) { releaseError = e; }
        }
        for (const modifier of pressed.reverse()) {
            try { controller.keyvalRelease(modifier); } catch (e) { releaseError ??= e; }
        }
        if (releaseError)
            throw releaseError;
    }
}
