#!/usr/bin/python3
"""GNOME's existing light choice becomes an explicit portal light preference.

GNOME 50's own buttons write default/prefer-dark. Keep those buttons intact;
normalize only default, never force a dark user choice or touch other settings.
The system-installed user service runs on the logged-in user's session bus.
"""
import os
import signal

from gi.repository import Gio, GLib

LIGHT_STYLE = 'light-style@gnome-shell-extensions.gcampax.github.com'


class LightStyleActivation:
    """Enable the packaged extension once Shell has actually discovered it.

    A new system extension is not discoverable in the current session. Do not
    inject Shell code or write an unknown UUID into its live enabled list.
    Listen for the normal discovery signal at the next session instead.
    """
    def __init__(self, bus):
        self.bus = bus
        self.complete = False
        self.pending = False
        self.closed = False
        self.subscription = bus.signal_subscribe(
            'org.gnome.Shell', 'org.gnome.Shell.Extensions', 'ExtensionStateChanged',
            '/org/gnome/Shell', LIGHT_STYLE, Gio.DBusSignalFlags.NONE,
            lambda *_: self.query())
        self.query()

    def query(self):
        if self.complete or self.pending or self.closed:
            return
        self.pending = True
        self.bus.call('org.gnome.Shell', '/org/gnome/Shell', 'org.gnome.Shell.Extensions',
                      'GetExtensionInfo', GLib.Variant('(s)', (LIGHT_STYLE,)),
                      GLib.VariantType.new('(a{sv})'), Gio.DBusCallFlags.NO_AUTO_START,
                      5000, None, self.ready)

    def ready(self, connection, result):
        self.pending = False
        try:
            info = connection.call_finish(result).unpack()[0]
        except GLib.Error as error:
            print(f'liuqin-appearance-sync: Shell discovery not ready: {error.message}', flush=True)
            return
        if self.closed or self.complete or not info:
            return
        settings = Gio.Settings.new('org.gnome.shell')
        for key in ('enabled-extensions', 'disabled-extensions'):
            if not settings.is_writable(key):
                print('liuqin-appearance-sync: extension choices are locked; left intact', flush=True)
                return
        self.complete = True
        enabled = settings.get_strv('enabled-extensions')
        if LIGHT_STYLE not in enabled:
            settings.set_strv('enabled-extensions', enabled + [LIGHT_STYLE])
        disabled = settings.get_strv('disabled-extensions')
        if LIGHT_STYLE in disabled:
            settings.set_strv('disabled-extensions', [uuid for uuid in disabled if uuid != LIGHT_STYLE])
        Gio.Settings.sync()
        print('liuqin-appearance-sync: packaged Light Style discovered and selected', flush=True)

    def close(self):
        self.closed = True
        self.bus.signal_unsubscribe(self.subscription)


class AppearanceSync:
    def __init__(self, settings):
        self.settings = settings
        self.handler = settings.connect('changed::color-scheme', self.sync)
        self.sync()

    def sync(self, *_args):
        if self.settings.get_string('color-scheme') != 'default':
            return
        if not self.settings.is_writable('color-scheme'):
            return
        # The resulting prefer-light notification cannot enter this branch,
        # so the normalizer does not create a signal/write feedback loop.
        if not self.settings.set_string('color-scheme', 'prefer-light'):
            raise RuntimeError('cannot store explicit light preference')
        Gio.Settings.sync()
        print('liuqin-appearance-sync: default -> prefer-light', flush=True)

    def close(self):
        self.settings.disconnect(self.handler)


def main():
    desktops = (os.environ.get('XDG_CURRENT_DESKTOP', '') + ':' +
                os.environ.get('XDG_SESSION_DESKTOP', '')).upper().split(':')
    if 'GNOME' not in desktops:
        return
    settings = Gio.Settings.new('org.gnome.desktop.interface')
    watcher = AppearanceSync(settings)
    activation = LightStyleActivation(Gio.bus_get_sync(Gio.BusType.SESSION, None))
    loop = GLib.MainLoop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, lambda: (loop.quit(), False)[1])
    try:
        loop.run()
    finally:
        activation.close()
        watcher.close()


if __name__ == '__main__':
    main()
