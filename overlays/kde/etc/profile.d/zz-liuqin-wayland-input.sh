# SPDX-License-Identifier: MIT
# Fcitx talks to KWin on Plasma Wayland; forcing toolkit modules bypasses
# text-input and prevents native touch keyboard requests. Keep XWayland IM.
if [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
    case "${XDG_CURRENT_DESKTOP:-}" in
        *KDE*)
            unset QT_IM_MODULE GTK_IM_MODULE
            QT_IM_MODULES='wayland;fcitx;ibus'
            XMODIFIERS=@im=fcitx
            export QT_IM_MODULES XMODIFIERS
            ;;
    esac
fi
