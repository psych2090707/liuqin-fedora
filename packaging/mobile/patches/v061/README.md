# 0.6.1 传感器用户态修复

来自 [liuqin Ubuntu v0.6.1](https://github.com/yzddmr6/xiaomipad-6pro-mainline/tree/v0.6.1/device/sensors)。
`preventive-patches.json` 保留上游原始来源及哈希记录，不能当成 Fedora 改写后的哈希清单。
上游还追溯到 Piano 的 RPC 修复、OnePlus Pad 2 Pro 的按传感器投递策略；保留逐文件许可。
hexagonrpc/libssc 的原 pin 不变；RPM spec 按顺序应用本目录补丁，并执行 Meson 测试。

Fedora 的差异：`0005-upstream-fetch-large-listener-inputs.patch` 适配在现有 write-stub 之后，
以 bounded inline/get_in_bufs2 代替实验的固定 1 MiB 分配。保留只写/丢弃的文件 stub，
另以根补丁 `0008-hexagonrpcd-restore-rom-property-allowlist.patch` 恢复原始两属性白名单。
先前实验放宽到所有属性并未修复 SLPI 复位，与现有 ROM 白名单测试冲突，不继续保留。

序列编码、非对齐访问、listener 大输入/失败继续回应、按传感器类型选择唤醒投递均纳入。
不会启动 SLPI，不等于自动旋转已修复。源代码构建、模拟测试和硬件 DSP 稳定性分别记录。
