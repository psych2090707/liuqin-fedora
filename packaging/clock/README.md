# liuqin-clock-support — 开机时间下限

目标：平板正常联网后保存可信时间，离线更新启动时不再退到过早日期而拒绝 RPM 签名。
保留 chronyd、GPG 校验、USB/网络/电源策略；不写 RTC、boot 或任何设备分区。
只保存时间，**不自行设置系统时钟**；恢复由 systemd PID1 原生实现。

## 复用与边界

- [systemd v259 `clock_apply_epoch()`](https://github.com/systemd/systemd/blob/v259/src/core/clock-warp.c)
  在 PID1 初始化时读取 `/usr/lib/clock-epoch` 的 mtime，早于离线更新服务。
  本机 `/usr` 在根分区、由自定义 init 直接交给根上的 systemd；不新增 initramfs。
- [社区同型配置](https://terinstock.com/post/2021/12/Systemds-clock-epoch-for-RTC-less-systems/)
  已有 epoch service/timer 做法。这里增加可信检查、关机保存和离线测试，避免无条件 touch 错误日期。
- [chronyc waitsync](https://chrony-project.org/doc/4.9/chronyc.html#waitsync) 做一次本地检查，
  要求已同步且剩余校正不超过 0.5 秒；走明确的 Unix socket，不发 DNS/UDP/NTP 请求。
- 同步时保存当前时间减 1 秒，并在 `/run/liuqin-clock/anchor.json` 保存本次 boot 的
  CLOCK_BOOTTIME 锚点；断网后最多 7 天按该单调时钟外推，不信任手工改动的墙上时间。
  BOOTTIME 包含 suspend 时间；锚点不跨启动使用，不假装提供了新的网络同步。
- 每约 60 秒保存一次，不唤醒睡眠设备；正常关机在 chronyd 停止前再保存。
  无可信源时不保存；文件/权限异常或旧 stamp 显著在未来时失败并留原件，不绕校验。
- 只能建立合理的启动日期下限，**不是精确 RTC 修复**：关机多久无法推算，
  突然断电可能损失最后约一分钟以上的进展（含调度/睡眠延迟）。未同步过、保存失败、
  异常复位恰在新包准备后等情形仍可能使离线签名校验失败，不能保证任意新签名均可用。

## 文件与更新存活

独立 noarch RPM 只包含 helper、两个 service 和一个不自动启用的 timer。
没有 RPM scriptlet、preset 或对 chronyd 的覆盖，避免重装整个 device-support 覆盖当前修复。
`/usr/lib/clock-epoch` 是管理员运行数据，**不作为 RPM payload/ghost**，避免更新或卸载把
mtime 变成打包时间、或删掉最后可信时间。现机已有 root:root、0644、空的该文件。
RPM 安装不修改它；首次激活需单独备份/授权。SELinux enforcing 下未验，不以 permissive 结果承诺。
helper 会 fsync 并读回 mtime；I/O/fsync 失败会报告 error，不能把内存中读到的新 mtime 当作已经可靠落盘。
服务只保留 `CAP_DAC_OVERRIDE` 以访问 chrony 自有且非其他用户可写的 Unix socket；
没有 `CAP_SYS_TIME`，文件系统只放行 epoch、自有 runtime 和 `/run/chrony` 的写入。
chronyc 4.9 的 Unix 查询会在服务端 socket 所在目录创建临时回信 socket，再自行清理；
该 runtime 放行不改 chronyd 配置，也不发送校时命令。显式 `chronyc -u root` 防止 Fedora
客户端再次降权触发被 sandbox 禁止的 setgroups/setuid；不授予 CAP_SETUID/GID 或 CAP_SYS_TIME。
实机验收必须在 chronyd
已同步时看到 service 的 `source=chrony`，不能仅看退出成功或 `source=holdover`。

## 离线构建与检查

```sh
python3 -B -m unittest discover -s tests/clock -v
bash scripts/build-clock-rpm.sh
```

构建仅使用已存在的 Fedora RPM builder，`--network=none --pull=never`，不联网装依赖。
默认候选在 `out/tn0094-store-update-audit/clock-candidate-v4/`；重复构建另指定新输出路径，
不清理其他任务产物。检查和实机授权/恢复步骤见
TN0094 结果。

## 待授权的实机步骤（本轮不执行）

所有命令都针对平板，**不是宿主机**。部署前核对本次候选 SHA256、设备仍是现有 Fedora/GNOME、
chronyd 已同步；重启和商店更新另行由用户确认，不在安装包时顺带触发。

1. 只读前检：包尚未安装，四个 payload 目标不存在；epoch 是 root:root、无组/其他用户写权限、
   单硬链接普通空文件；`/run/liuqin-clock` 若已有未知内容则停止核查，不覆盖。
   核对现有 chronyd 的配置/启用状态与内核 Build ID，保留其摘要作部署后对照。
2. 在 `/var/backups/liuqin-clock-TN0094-<本次标识>/` 建 root-only 备份，使用 `cp -a`
   保留 epoch 的**mtime 纳秒、owner/mode、SELinux 标签**；另记路径原先不存在的事实和 unit 状态。
   空文件 SHA256 恒定，**单独备份内容摘要不够回退时间下限**。
3. 用 `rpm -Uvh --test <候选.rpm>` 正常检查依赖/冲突，再只安装这个包；不加 `--nodeps`、
   不更新 device-support 或其他包。核对 `rpm -V liuqin-clock-support` 与 payload 摘要，
   确认安装本身没有改 epoch 或启用任何 unit；按系统现有规则 `restorecon` 新文件。
4. 仅此处才进入明确获准的激活：

   ```sh
   sudo systemctl daemon-reload
   sudo systemctl enable --now liuqin-clock-shutdown.service
   sudo /usr/libexec/liuqin/liuqin-clock-save --require-sync
   sudo systemctl start liuqin-clock-save.service
   sudo systemctl enable --now liuqin-clock-save.timer
   ```

   必须逐步确认成功；初次 `--require-sync` 不通过就停止激活，不改成无条件 touch。
   单次 service 还用于检查真实 systemd sandbox；读 journal 中 JSON source/status、epoch mtime、
   timer 的 WakeSystem=false，以及原 chronyd/USB/电源服务状态。失败即按下节撤销，不反复重启。
5. **实机验收另行确认**：一次正常重启看 PID1 的 `System time advanced to ... /usr/lib/clock-epoch`
   或实际启动时间，确认它早于离线更新、并保留同 boot ID/单调时间证据；随后在用户实际点击商店
   更新时核对事务成功与版本变化。不为测试故意把真机时钟拨错、不关闭网络、不跑完整刷机。
   更新列表可能已变，须重新检查不含未获准的专用内核/模块替换。

## 停用与完整回退（同样待授权）

先 disable/stop `liuqin-clock-save.timer`，停止可能仍在运行的 save service，最后 disable/stop
`liuqin-clock-shutdown.service`。**最后一步会执行一次 ExecStop 保存**，所以不能先恢复备份再停止它。

- 仅停用时可以保留最后可信 epoch，不必删包/删时间文件。
- 如需完整还原，先确认新 unit 全部停止，再正常 `rpm -e` 仅卸载本包并 daemon-reload，
  最后 `cp -a` 恢复备份 epoch 并读回 mtime/owner/mode/标签；不清理其他 runtime/备份目录。
  若原文件不存在则按备份事实处理，不能猜测删除。
- 恢复本机原先 1970 mtime 会重新暴露旧时钟回退/离线更新失败；这不是完整系统回滚，
  也不回退之后由商店安装的软件。
