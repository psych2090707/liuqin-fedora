# 启动构建兼容补丁

`abl-symbols-dtc-labels.patch` 修复锁定上游 `abl-symbols.py` 对新版 dtc 反编译输出的解析：
dtc 1.8.1 在 `-@` 模式下将 `__symbols__` 还原为节点前缀标签，导致 1781 标签的 ABL sink
被误判不存在。补丁只允许节点名前的合法标签，保留符号数量、指向、phandle 等全部原检查。

`scripts/build-bootimg.sh` 仅在 canonical stock-ROM 路径复制最小上游工具树，在临时副本应用补丁；
上游克隆不变。补丁哈希写入 boot build-info；上游修复此问题后应撤掉本兼容层。
该补丁不改变硬件 DTB 内容，不能替代设备启动验证。
