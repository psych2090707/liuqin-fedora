# 桌面开机准入检查

`sudo python3 tests/desktop-admission/test-admission.py` 在临时目录创建合成 root，
执行实际 `initramfs/init` 的准入函数。需要 root 是为了验证真实属主检查和 chroot；
不会访问设备、挂载或改动已安装系统，结束自动删除临时目录。

覆盖完整 KDE/GNOME、GNOME 无 KDE 依赖、选定路线不能降级放行、权限错误、
入口冲突、无入口、未知 alias、envelope 缺失/符号链接/损坏、root marker 错误与旧契约兼容。
PID1 是仅返回成功的静态合成程序；通过不等于真实 GNOME、系统启动或 ARM 硬件可用。

`python3 tests/desktop-admission/test-power-helper.py` 用命令替身运行上游适配的按键 helper，
覆盖空闲唤醒已亮屏不再次熄屏、手动亮灭、长按无动作、非 GNOME 会话跳过，以及 TN0097 的
幂等 `ensure-off`/`ensure-on`（不锁屏、失败不写缓存、root 调用切换到会话用户）。
不调用真实 D-Bus、按键或锁屏；用于代码逻辑的离线验证。

Rust 电源服务：`scripts/build-powerd.sh` 运行 `liuqin-power-core` 的 22 个状态机测试、
`cargo fmt --check` 和 aarch64 release 构建；旧的 Python 状态机测试仍保留用于回退验证。

`python3 tests/desktop-admission/test-lid-policy.py` 直接运行 TN0097 合盖状态机，
覆盖恢复后重新熄屏、开盖取消、输入/交流电/电源键取消重睡、20 秒窗口、快速恢复限流和
helper 连续失败暂停。

`python3 tests/desktop-admission/test-lid-service.py` 在私有 dbus-daemon 和独立假
UPower/logind/Mutter 进程上运行真实合盖服务，覆盖启动、显示变化、开合盖、恢复、logind/
GNOME 抑制与电源键标记。不连接真实桌面、设备或网络。

`python3 tests/desktop-admission/test-keyboard-nowake.py` 静态检查键盘套 nowake 规则仍在
桌面无关层、KDE 目录没有第二份副本，并在有 `udevadm` 时运行规则语法检查。

`node tests/desktop-admission/test-layout-reuse.mjs` 验证维护版 v6 键盘的布局复用、特殊用途隔离和临时状态复位，不运行 GNOME 或操作界面。
