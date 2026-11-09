#!/usr/bin/python3
"""Generate selected proposal A: five rows, 15 columns, native GNOME + IBus.

Widths are multiples of 0.5 (GNOME KeyContainer KEY_SIZE=2). The liuqin fields
are extension metadata; stock GNOME ignores them. No preview code is imported.
"""
import json
from pathlib import Path
import string

OUT = Path(__file__).resolve().parent / 'layouts'
SHIFT = dict(zip("`1234567890-=[]\\;',./", '~!@#$%^&*()_+{}|:"<>?'))


def char(value, shifted=False, caps=False, width=1):
    output = (value.upper() if caps != shifted else value) if value.isalpha() else (SHIFT.get(value, value) if shifted else value)
    d = {'strings': [output], 'width': width, 'liuqin': True}
    # Keep the familiar uppercase letter keycaps, independently of output.
    if value.isalpha():
        d['label'] = value.upper()
    if not shifted and value in SHIFT:
        d['liuqinShift'] = SHIFT[value]
    return d


def action(label, kind, width=1, **extra):
    return dict(label=label, action=kind, width=width, liuqin=True, **extra)


def raw(label, keyval, width=1, **extra):
    return dict(label=label, keyval=hex(keyval), width=width, liuqin=True, **extra)


def make_level(name):
    caps = name in ('caps', 'caps+shift')
    shifted = name in ('shift', 'caps+shift', 'opt+shift')
    fn = name in ('opt', 'opt+shift')
    default = 'caps' if caps else 'default'
    upper = 'caps+shift' if caps else 'shift'
    if fn:
        default, upper = 'opt', 'opt+shift'

    def c(value, width=1):
        if fn:
            special = {'`': ('Esc', 0xff1b), '[': ('Home', 0xff50), ']': ('End', 0xff57),
                       '\\': ('Ins', 0xff63), ';': ('PgUp', 0xff55), "'": ('PgDn', 0xff56)}
            special.update({value: (f'F{i}', 0xffbd + i) for i, value in enumerate('1234567890-=', 1)})
            if value in special:
                label, keyval = special[value]
                return raw(label, keyval, width)
        return char(value, shifted, caps, width)

    switch = action('Shift', 'levelSwitch', 2, level=default if shifted else upper,
                    iconName='osk-shift-symbolic', liuqinShape='pill')
    cap = action('Caps', 'levelSwitch', 1.5, level='default' if caps else 'caps')
    if fn:
        backspace = raw('Del', 0xffff, 2, liuqinShape='pill')
    else:
        backspace = action('⌫', 'delete', 2,
            iconName='osk-delete-symbolic', liuqinShape='pill')
    space = c(' ', 4)
    space['liuqinShape'] = 'pill'
    return dict(level=name, mode='locked' if caps or fn else ('latched' if shifted else 'default'), rows=[
        [c(v) for v in '`1234567890-='] + [backspace],
        [raw('Tab', 0xff09, 1.5)] + [c(v) for v in 'qwertyuiop[]'] + [c('\\', 1.5)],
        [cap] + [c(v) for v in "asdfghjkl;'"] +
        [raw('Enter', 0xff0d, 2.5, liuqinAccent=True, liuqinShape='pill')],
        [switch] + [c(v) for v in 'zxcvbnm,./'] + [switch.copy(), raw('↑', 0xff52)],
        [action('Ctrl', 'modifier', keyval='0xffe3'), action('Super', 'modifier', keyval='0xffeb'),
         action('Alt', 'modifier', keyval='0xffe9'),
         action('Fn', 'levelSwitch', level='default' if fn else 'opt'),
         action('中/英', 'languageMenu', iconName='osk-layout-symbolic'),
         raw('PrtSc', 0xff61) if fn else action('☺', 'emoji', iconName='osk-emoji-picker-symbolic'),
         space, raw('Home', 0xff50), raw('End', 0xff57),
         raw('←', 0xff51), raw('↓', 0xff54), raw('→', 0xff53)],
    ])


def layout(name, extra=False):
    return dict(locale='en', name=name, levels=[make_level(level) for level in
                ('default', 'shift', 'caps', 'caps+shift', 'opt', 'opt+shift')])


def validate(data):
    for level in data['levels']:
        assert len(level['rows']) == 5
        for row in level['rows']:
            assert sum(k.get('width', 1) for k in row) == 15
            assert all((k.get('width', 1) * 2) % 1 == 0 for k in row)
    reachable = {k['strings'][0] for level in data['levels'][:2] for row in level['rows'] for k in row if 'strings' in k}
    assert set(string.printable[:95]) <= reachable


def main():
    OUT.mkdir(exist_ok=True)
    for file, suffix in [('us.json', ''), ('us-extended.json', ' (terminal)'),
                         ('url.json', ' (URL)'), ('email.json', ' (email)')]:
        data = layout('English (United States) — Liuqin A' + suffix)
        validate(data)
        target = OUT / file
        target.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
        print(f'wrote {target}: proposal A, 15×5, 6 levels, 95 printable ASCII')


if __name__ == '__main__':
    main()
