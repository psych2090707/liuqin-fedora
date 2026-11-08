@echo off
rem SPDX-License-Identifier: MIT
rem Convenience wrapper: double-click or run from cmd.exe with the same
rem arguments as install-liuqin.ps1, e.g.  install-liuqin.cmd doctor --json
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-liuqin.ps1" %*
exit /b %ERRORLEVEL%
