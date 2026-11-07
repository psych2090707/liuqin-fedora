# 离线检查：只运行受影响的部分

| 修改对象 | 检查入口 | 证明范围 |
|---|---|---|
| GNOME 按键/合盖/输入 | [desktop-admission](desktop-admission/README.md) | 合成输入、状态机、私有测试总线；不操作桌面或真实设备 |
| boot 更新元数据/回退逻辑 | `tests/boot-update/` | 合成镜像和文件；不能当真实内核更新验收 |
| 固件/设备验证/构建适配 | `tests/integration/test-firmware-pool.py`、`tests/device-validation/` 等 | 先看具体脚本是否依赖产物或写 rootfs，不默认全跑 |
| WCD938x RX 中断空指针 | [audio-driver/test-wcd938x-irq.py](audio-driver/test-wcd938x-irq.py) `--source <实际源码>` | 编译实际回调，模拟 RX 无 regmap 与 TX 状态处理；不是硬件中断或睡醒验收 |
| 充电认证受控候选 | [charging/test-staged-auth.py](charging/test-staged-auth.py) | 假 sysfs 下角色请求/SVID/HMAC/失败清理分支；不是实机认证或功率验收 |
| 旧安装器 | `tests/installer/` | 历史布局与协议的定向回归，不安装当前平板 |

离线与实机结论分开。文档修改不构建系统、不运行 QEMU 整机模拟或硬件检查。
