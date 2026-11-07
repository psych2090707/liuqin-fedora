# SPEC 变更建议：固件闭包（task-25 审计结论）

> 状态：**建议（proposal）**，未直接修改其他 Agent 的 spec/脚本。执行者：device-packager / Lead。
> 依据：docs/maintenance/firmware-closure.md；证据：`out/firmware-audit/`。
> 核心结论：**不需要新增 rootfs 包**（F44/F45 都有 `cirrus-audio-firmware`，generic 文件哈希相同）；
> 需要的是**依赖声明、release-gate 校验与旧文档口径修正**。

## 1. `packaging/device/liuqin-audio.spec`：增加 `Requires: cirrus-audio-firmware`

**理由**：四扬声器需要 Fedora 子包 `cirrus-audio-firmware` 提供的
`cirrus/cs35l41-dsp1-spk-prot.{wmfw,bin}`；缺失时驱动 fail-closed 静音。`mkosi` 配置为
`WithRecommends=false`，弱依赖不会被安装，因此必须是硬依赖。`liuqin-audio` 拥有
topology/UCM，是"音频可用"的包，声明此依赖语义正确。

```diff
@@ %description 前 / Requires 区域
 Requires:       alsa-ucm
+# The four CS35L41 speaker amplifiers load cs35l41-dsp1-spk-prot.{wmfw,bin}
+# from Fedora's cirrus-audio-firmware subpackage; without it the driver
+# fail-closes to muted (no speaker sound).  mkosi uses WithRecommends=false,
+# so this must be a hard Requires, not Recommends.
+Requires:       cirrus-audio-firmware
```

可选（不强制）：`Requires: linux-firmware` 已由 base 提供，不需要显式写；若担心 F44/F45
子包改名，可写 `Requires: (cirrus-audio-firmware or linux-firmware)`（RPM rich dependency，
F44 rpm 支持），但当前两版本线包名稳定，建议简单硬依赖。

## 2. `packaging/device/liuqin-firmware.spec`：保持"不含 cirrus/regulatory/topology"，加断言

**理由**：CS35L41 generic 属 Fedora 可再分发固件，不应进入 `Proprietary` 的本地包；
per-device calr 属设备私有数据，更不得打包。当前 spec 已省略 regulatory/topology，
但 `%prep` 未显式断言上游树不含 `cirrus/`（上游 `device/firmware` 目前确实没有）。
建议加断言，防止未来 upstream 更新夹带：

```diff
@@ %prep 末尾（197/4 文件计数断言之后）
 [ "$(find "$work/usr/lib/firmware" -type l | wc -l)" = 4 ] ||
 	{ echo 'staged firmware tree does not hold 4 symlinks' >&2; exit 1; }
+# Ownership policy: Fedora provides the redistributable Cirrus CS35L41 generic
+# firmware and the wireless regulatory database; per-device CS35L41 calibration
+# comes from the user's persist at provisioning time.  Never package them here.
+[ ! -d "$work/usr/lib/firmware/cirrus" ] ||
+	{ echo 'upstream firmware tree unexpectedly contains cirrus/ (Fedora-owned)' >&2; exit 1; }
+[ ! -e "$work/usr/lib/firmware/regulatory.db" ] ||
+	{ echo 'upstream firmware tree unexpectedly contains regulatory.db (wireless-regdb)' >&2; exit 1; }
```

并在 spec 头注释补充一行（已有 ownership policy 段落）：

```diff
 #  * qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin is omitted (liuqin-audio owns it);
+#  * cirrus/ CS35L41 generic firmware is NOT packaged: Fedora's
+#    cirrus-audio-firmware subpackage provides it (F44/F45).  Per-device
+#    cs35l41-liuqin-<ch>-calr.bin is provisioned from persist and must never
+#    enter a generic image.
 #  * ath11k/WCN6855/** is relocated to /usr/lib/firmware/updates/ath11k/**
```

## 3. `scripts/build-device-rpms.sh` 的 verify 阶段：加固件归属断言

在容器内验证三个 RPM 的 `%files` 之后追加（示意，具体函数名按现有脚本调整）：

```sh
# firmware ownership closure (docs/maintenance/firmware-closure.md)
assert_rpm_lacks() { # rpm-path pattern description
    rpm -qpl "$1" | grep -q "$2" && die "$3: $1 contains $2"
    return 0
}
assert_rpm_lacks out/rpms/liuqin-firmware-*.rpm '/usr/lib/firmware/cirrus/' \
    'CS35L41 generic firmware must come from Fedora cirrus-audio-firmware'
assert_rpm_lacks out/rpms/liuqin-firmware-*.rpm '/usr/lib/firmware/regulatory.db' \
    'regulatory.db belongs to Fedora wireless-regdb'
assert_rpm_lacks out/rpms/liuqin-firmware-*.rpm 'Xiaomi-Pad-6-Pro-tplg.bin' \
    'audio topology belongs to liuqin-audio'
```

## 4. Release gate：新增固件闭包检查（`scripts/verify-bundle.sh` / `scripts/build-image.sh`）

建议由 image-build owner 在 bundle 验证中调用（脚本资产先落到 repo，例如
`packaging/firmware/`，内容来自 `out/firmware-audit/`；不要直接依赖 `out/`）：

```sh
# after the assembled rootfs and boot/initramfs exist:
packaging/firmware/check-firmware-closure.sh \
    --rootfs "$ASSEMBLED_ROOTFS" \
    --initramfs-info "$BOOT_META/initramfs-info.json" \
    --firmware-pool "$FIRMWARE_POOL" \
    --json "out/ci/firmware-closure.json"
```

需要随包/随 repo 携带的资产：

| 资产 | 当前来源（out/firmware-audit/） | 建议 repo 位置 |
|---|---|---|
| `release-gate-firmware.sha256` | 已生成 | `packaging/firmware/closure.sha256` |
| `release-gate-packages.txt` | 已生成（F44 NEVRA pin） | `packaging/firmware/packages.txt` |
| `device-private-must-not-be-in-image.txt` | 已生成 | `packaging/firmware/device-private.txt` |
| `initramfs-pool-pins.txt` | 已生成 | `packaging/firmware/initramfs-pool.txt` |
| `liuqin-firmware-symlinks.tsv` | 已生成 | `packaging/firmware/liuqin-firmware-symlinks.tsv` |
| `suggested-release-gate-check.sh` | 已自测 | `packaging/firmware/check-firmware-closure.sh` |

检查语义（脚本已实现）：
1. assembled rootfs 的 `sha256sum` 清单（Fedora 4 + liuqin-firmware 194 + 4 symlinks）；
2. Fedora 固件包 NEVRA 与 pin 一致（CI 容器内有 rpm 时）；
3. 设备私有数据必须缺席（calr/MAC/BT/registry）；
4. `initramfs-info.json` 的 8 类固件全部 staged 且 `device_ready=true`；
5. `--firmware-pool` 时按 `build-initramfs.sh` 的 pin 校验 touch/BT set/WLAN/GPU/DSP set/
   regulatory/VPU/topology/HSP2 tuple。

## 5. 镜像/bundle 元数据（`scripts/build-image.sh` 或 bundle.json）

建议在 `bundle.json` 增加（含值示例，供 image-build owner 采纳）：

```json
"firmware_closure": {
  "cs35l41_generic": {
    "provider": "cirrus-audio-firmware",
    "manifest": "packaging/firmware/closure.sha256",
    "verified": true
  },
  "device_private_present": false,
  "initramfs_firmware_staged": ["touch", "bluetooth", "wlan", "regulatory", "gpu",
                                "dsp", "wlan-hsp2", "audio-topology"]
}
```

并在 `device_ready_reasons` 中保持：缺 `cirrus-audio-firmware`、缺 initramfs 固件池、
未实机验证时不得为 true。

## 6. Provisioning / 安装器：校验 4 个 calr 文件

`tools/provision-liuqin-from-persist.sh`（upstream）已生成 calr；建议在安装器
（`installer/install.py` 或 device-side provisioning wrapper）完成后断言：

```sh
for ch in TL TR BL BR; do
  f=/usr/lib/firmware/cirrus/cs35l41-liuqin-$ch-calr.bin
  [ -f "$f" ] && [ "$(stat -c '%s' "$f")" = 4 ] && [ "$(stat -c '%a' "$f")" = 600 ] || \
      die "CS35L41 calibration missing/invalid: $f (audio would fail-closed to mute)"
done
[d "$(stat -c '%s' /var/lib/liuqin-private/wlan-mac)" ... ]  # 既有 provisioning 检查
```

这些文件只允许出现在设备上；release gate 的 `device-private-must-not-be-in-image` 会反查
镜像/bundle 中不得包含。

## 7. 文档改动（建议由各文档 owner 采纳）

| 文件 | 改动 |
|---|---|
| `docs/hardware-support.md` | 音频 CS35L41 行：由 `cirrus-audio-firmware` 提供（F44/F45 均有）；known gap 改为 per-device calr + 实机未验证；已知限制 2 同步 |
| `tools/diagnose.sh` | `firmware.cs35l41_dsp` 接受 `.xz/.zst`（Fedora 压缩形态）；`firmware.cs35l41_calr` 保持 device/known-gap |
| `docs/device-validation/*` | 旧口径 "cs35l41 不在 linux-firmware / 待解决" 更新为本文结论；SELinux 行按 ADR-0002 附注改为 permissive（首版） |
| `docs/maintenance/device-packages.md` | 指向本文作为固件闭包权威说明；音频包依赖变更同步 |
| `docs/build/image-build.md` | device_ready 原因中的"固件池未提供"保持；补一句 cirrus 由 rootfs 包提供，无需进 pool |

## 8. 不建议的改动（避免踩坑）

- **不要**把 Fedora 的 `cirrus-audio-firmware` 文件复制进 `liuqin-firmware` 或 bundle：
  许可路径清晰、体积与升级都由 Fedora 管理，复制会引入双份文件/哈希漂移风险。
- **不要**为了"统一"而把 `linux-firmware` 从包集移除：`atheros-firmware`/`qcom-firmware`
  除 liuqin 覆盖文件外仍提供其他硬件固件与 WHENCE 元数据；保留显式包集。
- **不要**把 `updates/ath11k` 改回主树或删除 Fedora 的 `ath11k/...xz`：当前依赖
  `updates/` 优先级 + raw/压缩共存来覆盖，RPM 文件冲突为 0，改动会破坏版本可回退性。
