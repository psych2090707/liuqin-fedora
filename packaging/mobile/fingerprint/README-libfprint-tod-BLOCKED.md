# 已撤销（superseded）：libfprint-tod 不再阻塞

**2026-10-20 / TN0034**：本文原来的结论（"禁止 Ubuntu 源包 → TOD 不可构建 → 自行移植 TOD ABI"）
经复核撤销。TOD 源码是 Ubuntu 维护的 **LGPL-2.1+ 开源源码**，已锁定在 liuqin 上游
`device/fingerprint/oem/SOURCE_LOCK.json`，现在直接复用该源码重新构建 Fedora RPM。

- 新文档（结论/设计/验证/边界）：**[README-libfprint-tod.md](README-libfprint-tod.md)**
- 任务记录：`tasks/archive/TN0034-fingerprint-tod-reuse/`
- 构建入口：`scripts/build-mobile-rpms.sh fingerprint-tod`

当时的“无法构建”结论已撤销；当前指纹录入/解锁与睡眠唤醒证据见 docs/STATUS.md 和 TN0064 RESULT。
