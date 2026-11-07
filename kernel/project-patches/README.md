# liuqin 项目自有内核补丁

本目录默认 `series` 已含显示 0001、蓝牙清理 0002 与 rpmh 0008。当前设备还显式使用的诊断、USB、音频输入集中在 [device-extras](../device-extras/README.md)，不自动加入本队列。实际启动身份和验证边界见启动专题。

`kernel/patches/` 是从锁定上游产品树导出的只读队列（不可手改）；本目录存放**本项目在实机上
验证过、上游尚未包含**的修复。`scripts/build-kernel.sh` 在 `git archive` 解出锁定源码后，
按 `series` 顺序把这里的补丁应用到临时源码树（上游克隆不被修改；已应用则跳过），并把每个补丁的
文件名与 sha256 写入 `build-info.json` 的 `source.project_patches`。

| 补丁 | 作用 | 实机证据 |
|---|---|---|
| `0001-arm64-dts-qcom-liuqin-vote-display-bandwidth-on-apps-bcms.patch` | MDSS `mdp0-mem`/`mdp1-mem` 改投 `MASTER_MDP → SLAVE_EBI1`，修复 CPU 深度空闲后显示 DDR/NoC 带宽被 RPMh sleep 集合清零导致的 DPU CTL 卡死与花屏 | TN0050 RESULT 第四轮 |
| `0002-bluetooth-hci_qca-cleanup-on-all-setup-failures.patch` | 上游 `5c4e9a8b1845`：`qca_setup()` 最后一次初始化失败也执行断电清理并置 `QCA_BT_OFF`，避免 `QCA_IBS_DISABLED` 残留使每次 `qca_suspend()` 返回 `-ETIMEDOUT` 拖住系统睡眠 | TN0103 |
| `0008-upstream-f87412d18edb-rpmh-rsc-clear-trigger.patch` | 上游 `f87412d18edb`：rpmh-rsc 清理 trigger，避免 s2idle 睡死；日用 `-zram1` 已包含 | TN0071 结果 |

规则：只收录有实机证据的最小修复；每个补丁头写清根因与验证方式；新增/修改后需重建内核并
重新验证产物，旧 bundle 不会因源码改动而更新。上游合入后应从 `series` 中移除。
