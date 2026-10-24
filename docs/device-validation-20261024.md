# LX06 实机验收：2026-10-24

设备为小爱音箱 Pro LX06，系统版本 1.94.13，操作主机为晨的 Mac mini。
Wi-Fi 地址 `192.168.1.11`，蓝牙地址 `EC:41:18:6E:AF:06`。

## 完成结果

蓝牙开机固件已通过 USB 写入并读回比较 SHA-256。镜像为
`be8ca2f00a075496005b892674ea89c665e23c56be95d3e2bd8662c55b324bc7`。
`/etc/rc.local` 自动启动 RFCOMM 通道 23，转发到本机 Dropbear 端口 22。
保留 SSH 主机密钥核验、公钥登录、蓝牙认证及链路加密。

最终软件重启后的启动 UUID：`fba31f82-055e-445f-bc9d-4ba4c0a5c90f`。
Wi-Fi 与蓝牙均核验 root、LX06、1.94.13、boot0，且 UUID 相同。
首次蓝牙连接 1.63 秒；随后三次 CLI 复验分别为 1.53、1.22、0.94 秒。
256 KiB 随机数据通过蓝牙 SSH 往返逐字节一致，SHA-256 为
`107863ee49f01ee635ee3f6607880100cf8abcc599576293a18d20d0a0e90a48`。
验收期间没有手动启动临时蓝牙监听。

结果文件：`.cache/bluetooth-autostart-flash.json`、
`.cache/bluetooth-autostart-acceptance.json`、`.cache/bt-fixed-acceptance.log`、
`.cache/final-device-state.txt`。

## 软件进入 USB 烧录模式

先通过 root SSH 只读备份 `/dev/mtdblock4` 和 `/dev/nand_env`。
40 MiB system0 的设备端与本地 SHA-256 相同：
`ee28bc9c503766c40ed6530917167b9c1f300052f73c295a0bbfa26763d3699a`。
64 KiB 启动环境 CRC32 通过，本地保存了环境全文和原始字节。

临时将 preboot 改为 `run storeargs; update 10000 10000;`，读回确认仅此字段改变，
先启动 CLI diagnose，再通过 SSH 重启。USB 握手成功，USB 完整备份与 SSH 备份一致。
该验证说明延长入口并覆盖软件重启路径在本次硬件连接下有效，不能据此唯一解释此前所有未枚举事件。

随后在 U-Boot 中恢复原 preboot 和 identifyWaitTime，saveenv 后读取核对。
先恢复已验证原版 system0，再按 CLI flash 的原版基线规则写入新固件，两次写入均完成读回校验。
最终 Linux 再次核对：

```text
preboot=run storeargs;if test ${reboot_mode} = cold_boot; then run try_auto_burn; fi;
identifyWaitTime=1000
boot_part=boot0
bootdelay=1
```

原系统备份目录：

- `~/Library/Application Support/XiaoaiWorkbench/Backups/LX06-ssh-pre-bluetooth-20261024-021713`
- `~/Library/Application Support/XiaoaiWorkbench/Backups/LX06-controlled-entry-20261024-0220/Backup`
- 原版恢复基线：`~/Library/Application Support/XiaoaiWorkbench/Backups/LX06-powercycle-20261024-011808`

本次使用了检查过的维护脚本。临时修改 preboot 的流程尚未新增为工作台正式 CLI 子命令，
不应将上述记录直接当作其他设备的通用刷机脚本。

## 修复的两个问题

1. `Workbench.rebootAndVerify` 原来依赖音箱不存在的 `nohup`，后台命令启动失败。
   改为 shell 忽略 HUP 后启动延时重启，继续以启动 UUID 改变及身份检查作为成功条件。
   已通过打包后的 `reboot-verify` 实机验证。Sources、Tests、docs 中没有其他同类 nohup 调用。
2. Mac RFCOMM 代理原来在通道打开后立即发送 SSH 数据。设备 BlueZ 的
   `cmd_listen` 在准备 TTY 时执行 `TCFLSH/TCIOFLUSH`，可能清除提前到达的数据。
   [BlueZ 5.37 源码](https://github.com/bluez/bluez/blob/5.37/tools/rfcomm.c)与实机 strace 均确认该动作。
   暂停 listener 1 秒再恢复，旧客户端卡在 SSH 密钥交换并超时；修复后相同条件 root 登录成功。
   Mac 代理现等待服务端首包再转发客户端数据，连接超时覆盖等待首包阶段。
   只有一个 RFCOMM 客户端转发实现需要修改；现有固件不需要再次刷写。

回归测试 `scripts/test-bluetooth-proxy.py` 用延迟就绪的传输替身执行实际 Objective-C 代理代码。
旧代码实测退出 42，报告过早发送；新代码通过，且验证 4 字节 MTU 分块后的完整内容。
原版与修复后实机复现分别保存在 `.cache/bt-race-before.json` 和 `.cache/bt-race-after.json`。

## 构建与限制

33 项 Swift 测试通过，12 项打包 CLI 离线用例通过，新增蓝牙就绪回归通过。
应用重新打包，深度严格签名校验与 `dist/SHA256.json` 文件校验通过。
目录没有 Git 仓库，未进行提交。

最终验证覆盖软件重启，修复后的客户端尚未额外经历物理拔电冷启动或长时间压力测试。
诊断中还出现过一次立即重连时的 macOS RFCOMM open 错误 `0xe00002bc`；
最终连续三次重连均通过，未添加自动重试，也未将该独立错误判定为已定位。
音频、麦克风和蓝牙音频播放不在本轮验收范围。Wi-Fi ADB 与 USB ADB 未启用。

后续双槽位备份及无线升级验收见 [OTA 验收记录](ota-validation-20261024.md)。以上保留为此前 USB、SSH 阶段的记录。
