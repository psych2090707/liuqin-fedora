# Liuqin 屏幕键盘

维护中的 GNOME Shell 51 屏幕键盘扩展（`liuqin-tablet-keyboard@liuqin`）。它保留自己的
5 行 15 列电脑键布局，使用原生 GNOME/IBus 输入链路，不引入 Maliit 或其他键盘后端。

> 2026-11-09：保留 v8 外观和键盘套弹出策略；v9 撤销强制移动预编辑光标，
> 已安装，待下次正常登录加载。输入设置改用 libpinyin 自带的兼容显示模式；
> 用户已确认终端/记事本输入法 CSS、终端光标正常；菜单搜索间歇首字母问题未定因，见键盘结果。

## 文件

| 路径 | 用途 |
|---|---|
| `extension/` | 扩展源码、布局资源、浅色/深色 CSS |
| `extension/stylesheet.css` | 两套配色共用的尺寸、间距、圆角、字号（含 IBus 候选气泡几何） |
| `extension/stylesheet-light.css` / `-dark.css` | Material 3 颜色角色，由 `-st-accent-color` 用 `st-mix()` 派生；Shell 按当前变体自动只加载一个 |
| `extension/popup-policy.js` | 键盘套吸附时不自动弹出、保留底部上滑的纯逻辑 |
| `build/gen_layouts.py` | 生成 `us.json`、`us-extended.json`、`url.json`、`email.json` |
| `build/build.sh` | 重新生成布局并打包 `osk-layouts.gresource` |
| `apply-input-settings.sh` | 输入法安全基线；`v`/预编辑的尝试已撤回，脚本不再关闭英文模式 |

## 构建与检查

```sh
bash overlays/gnome-local/keyboard/build/build.sh
node tests/desktop-admission/test-keyboard-popup-policy.mjs
node tests/desktop-admission/test-layout-reuse.mjs
tasks/keyboard-material3/integration-harness/run.sh light /tmp/opencode/kbint-light.png
tasks/keyboard-material3/integration-harness/run.sh dark /tmp/opencode/kbint-dark.png
```

集成脚手架在宿主机 headless GNOME Shell 51.1 中加载真实扩展和假 IBus panel service，
验证拼音芯片、选中候选、胶囊键和收起图标；它不碰平板或当前桌面会话。

`build.sh` 只更新 `extension/osk-layouts.gresource` 和 `extension/expected.sha256`；
中间目录 `build/layouts/`、`build/osk-layouts.gresource` 不需要提交。

## 部署

扩展文件属于系统目录。先备份整个
`/usr/share/gnome-shell/extensions/liuqin-tablet-keyboard@liuqin/`，再复制
`extension/.` 到该目录。Wayland 下扩展 JS 有模块缓存，**新 JS 必须重新登录或重启
Shell 才会加载**；只改 CSS 时 `gnome-extensions disable/enable` 可以重载样式。

`org.gnome.desktop.a11y.applications screen-keyboard-enabled` 保持为 `true`。
键盘套吸附时扩展会拦截焦点自动弹出，但 GNOME 仍需要该开关保留键盘 actor，
底部上滑手势才能在吸附状态下打开键盘。

输入法设置按当前桌面用户执行：

```sh
overlays/gnome-local/keyboard/apply-input-settings.sh
```

当前脚本把 `display-style` 设为 `2`（兼容模式），由原生候选框显示拼音，
不改 `english-input-mode`。扩展只观察预编辑文字用于标题，不改引擎光标和选择。
此前关闭英文开关与首字母异常同时发生，因果关系尚未确认；详见键盘结果。

## 回退

- 恢复备份的扩展目录并重新登录。
- `gsettings set com.github.libpinyin.ibus-libpinyin.libpinyin english-input-mode true`
- `gsettings set com.github.libpinyin.ibus-libpinyin.libpinyin display-style 1`

## 日志

```sh
journalctl -b -o cat | grep liuqin-osk-layout
```

应能看到 `popup policy patched`、`touch mode tablet (no cover)` 或
`touch mode laptop (cover attached)`，以及布局资源 SHA256 校验结果。
