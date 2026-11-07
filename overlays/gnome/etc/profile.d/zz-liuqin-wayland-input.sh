# SPDX-License-Identifier: MIT
# Explicit GNOME route; the KDE branch is recovery-only, not a dependency.
if [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
    case ":${XDG_CURRENT_DESKTOP:-}:" in
        *:GNOME:*)
            INPUT_METHOD=ibus
            GTK_IM_MODULE=ibus
            QT_IM_MODULE=ibus
            QT_IM_MODULES='wayland;ibus'
            XMODIFIERS=@im=ibus
            SDL_IM_MODULE=ibus
            GLFW_IM_MODULE=ibus
            export INPUT_METHOD GTK_IM_MODULE QT_IM_MODULE QT_IM_MODULES
            export XMODIFIERS SDL_IM_MODULE GLFW_IM_MODULE
            ;;
        *:KDE:*)
            unset GTK_IM_MODULE QT_IM_MODULE
            INPUT_METHOD=fcitx
            QT_IM_MODULES='wayland;fcitx;ibus'
            XMODIFIERS=@im=fcitx
            SDL_IM_MODULE=fcitx
            GLFW_IM_MODULE=ibus
            export INPUT_METHOD QT_IM_MODULES XMODIFIERS SDL_IM_MODULE GLFW_IM_MODULE
            ;;
    esac
fi
