#!/usr/bin/env bash
# ibus-libpinyin settings used by the Liuqin OSK.
#
# Compatibility display sends pinyin to the native IBus auxiliary label,
# without compact mode's inline preedit at cursor offset zero. This avoids
# rewriting the engine's cursor in the Shell extension. See keyboard RESULT.
# Keep the English-mode choice separate from display configuration: the
# first-letter problem observed on 2026-11-08 has not been traced to that switch.
set -euo pipefail

schema=com.github.libpinyin.ibus-libpinyin.libpinyin

if ! gsettings list-schemas | grep -qx "$schema"; then
    echo "ibus-libpinyin schema not installed: $schema" >&2
    exit 1
fi

# Native candidate-panel pinyin; no inline Chinese guess or duplicate caret.
gsettings set "$schema" display-style 2

printf 'english-input-mode=%s (unchanged)\n' \
    "$(gsettings get "$schema" english-input-mode)"
printf 'display-style=%s\n' "$(gsettings get "$schema" display-style)"
