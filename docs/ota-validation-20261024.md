# LX06 无线 OTA 验收记录

日期：2026-10-24，Asia/Shanghai。设备 LX06 / 1.94.13，地址 192.168.1.11，蓝牙 EC:41:18:6E:AF:06。执行主机：晨的 Mac mini。本文记录本机实测，不外推至其他型号或固件版本。

## 备份与分区分析

启动镜像各 6 MiB，system0 为 40 MiB，system1 为 40 MiB + 128 KiB。system1 最后 128 KiB 读取失败，内核报告一个坏块；前 40 MiB 两次读取一致并可完整解包，原备用系统版本 1.88.221。无线备份明确保存每个系统分区前 40 MiB，无法称为完整原始 NAND 备份。

备份均位于 `~/Library/Application Support/XiaoaiWorkbench/Backups/`：

| 目录 | 用途 |
| --- | --- |
| `LX06-powercycle-20261024-011808` | 先前保留的原版 USB 恢复基线 |
| `LX06-ota-slots-20261024-023711` | 独立分区分析、启动环境 CRC 检查 |
| `LX06-OTA-verified-20261024-025252` | 正式 CLI 双槽位备份，与独立备份四个分区哈希一致 |
| `LX06-OTA-boot1-20261024-031022` | Wi-Fi 升级提交后的 boot1 基线，用于反向蓝牙升级 |

正式备份包含四个分区文件、64 KiB 启动环境和元数据。读取后再次计算设备端哈希，并核对传输及落盘内容。首份正式备份的启动环境 CRC 也经独立脚本检查。

## 实机结果

| 操作 | 结果及证据 |
| --- | --- |
| Wi-Fi CLI 升级并暂不确认 | boot0 切至 boot1，事务 `ef21a218-63f7-4926-aa05-b5e98dec517b`；`.cache/ota-trial1-result.json` |
| 90 秒无确认自动回退 | 设备计时器自行重启，回到 boot0；启动 UUID `34355d1e-f18d-4a2a-9024-c792dd3f39a7`；`.cache/ota-timeout-observation.jsonl` |
| 回退完整性 | 原 boot0 内核及完整 40 MiB system0 哈希不变，原 preboot 恢复，boot_failcnt=0；`.cache/ota-timeout-rollback-integrity.txt` |
| 蓝牙 CLI 显式回退 | boot1 回到 boot0，UUID `fbd87b4b-e3be-4da0-af44-f75cf8c2a6fc`；`.cache/ota-bluetooth-rollback-result.json` |
| 修复后 GUI Wi-Fi 升级 | 自动提交至 boot1，事务 `14c5df4a-aaa2-4d34-bdbc-0354dafe9b35`，UUID `f596a8c9-4c0c-423b-9a07-c79ff754e9eb`；GUI 显示升级已确认；`.cache/ota-gui-success.json` |
| 蓝牙 CLI 完整升级 | boot1 升级至 boot0 并自动提交，事务 `f76b85ce-7607-48fd-a031-4fdb29229ff1`，UUID `d66edfac-9cf0-4514-b047-b789775fe81c`，耗时 614.27 秒；`.cache/ota-bluetooth-install-result.json` |

升级包位于 `~/Library/Application Support/XiaoaiWorkbench/OTAPackages/LX06-1.94.13-local-ota-20261024/`。

| 内容 | SHA-256 |
| --- | --- |
| 1.94.13 配套内核，6 MiB | `f38a880f0c7e7f12bbaced111d5e210d89a38158d1b26e9fb7b5f60f210442d2` |
| 新 root.squashfs，38486016 字节 | `c5c89b608fde13a37269aeb7bf52f7324ba509dd5a8f401d7263f606a8b0d764` |
| 升级前已解锁的完整 system0，40 MiB | `2c7892813bcc2318f1c4d46e26b01fa06b324c1a59b4b090c61aa1b85c0cbbaa` |

## 最终重启与 GUI 验证

再次通过正式 `reboot-verify` 重启成功，启动 UUID 变为 `ea6bdd3f-0eab-47e9-bb1c-3d97582c5f87`，仍为 boot0 / committed，root SSH 和蓝牙监听正常。最终版 GUI 在用户允许蓝牙后，于 03:22:42 通过蓝牙查询成功，03:23:00 通过 Wi-Fi 查询成功，两者显示相同事务。会话日志为 `~/Library/Application Support/XiaoaiWorkbench/session-B4ADA333-CF8D-49AC-9115-63287A794CBA.log`。

独立读回两个槽位的完整内核及新系统镜像长度，均与升级包哈希一致。原 preboot 已恢复，boot_failcnt=0。证据为 `.cache/ota-final-device-integrity.txt`、`.cache/ota-final-reboot-result.json`、`.cache/ota-final-bluetooth-status.json`；汇总见 `.cache/ota-validation-result.json`。当前 boot1 保留本轮之前已验证的新固件，可以作为 boot0 的回退点。

## 验收中修复

1. 上轮 `rolled_back` 环境标记覆盖新事务 `writing`，使 GUI 提前报回退。增加环境事务 ID 与状态文件事务 ID 的对应检查。保留了出错轮次记录 `.cache/ota-gui-trial-confirm.json`，修复后重新完整执行 GUI 升级并通过。
2. SSH 的 known_hosts 配置值包含空格，旧格式造成路径截断。对 OpenSSH 配置值正确加引号，实测使用预期的专用文件，保留主机公钥校验。
3. GUI 局域网连接受 macOS 隐私权限影响。加入应用自身的连接请求，使用稳定 Apple 签名并安装到 `/Applications`，GUI Wi-Fi 实测通过。蓝牙权限由用户手动允许。
4. 写入进程因重启消失后，持久状态可能仍为 writing。状态查询结合临时锁判为失败，后续安装重新检查基线和镜像；专门回归测试覆盖此恢复路径。

## 自动化验证

- Swift：36 项测试通过，日志 `.cache/ota-tests.log`。
- 实际设备端 shell 与引导脚本替身：22 项检查通过，日志 `.cache/ota-agent-tests.log`。涵盖校验失败、写入失败、读回错误、环境切换失败、未确认回退、旧事务标记及失去写入进程后的恢复。
- 打包 CLI 离线回归：12 项通过，日志 `.cache/ota-cli-tests.log`。
- 蓝牙代理延迟就绪回归通过，日志 `.cache/ota-bt-test.log`。

## 范围与限制

GUI 和 CLI 共用 OTA 实现，Wi-Fi 为主通道，蓝牙 RFCOMM 承载相同 SSH 事务。本地镜像经 SSH 上传，不依赖小米云端 OTA。写入只覆盖非当前槽位，全部文件上传和哈希核对完成后才开始。

实机故障演练覆盖新系统上线后不确认引发的自动回退。未进行写入中物理断电、原始 NAND 损坏或内核故意卡死实验。若内核尚未启动到计时器就卡死，需断电重启触发引导回退；bootloader、启动环境或双槽位损坏仍可能需要拆机 USB 恢复。音频、麦克风及长时间稳定性不在本轮验收范围。

## 最终应用

0.2.0（build 2）已安装至 `/Applications/XiaoaiWorkbench.app`，Apple 签名深度严格验证通过，35 个文件与 `dist/SHA256.json` 一致。最终安装版离线 CLI 回归 12 项通过，日志 `.cache/ota-cli-tests-final.log`。未上传或公证。目录没有 Git 仓库，未创建提交。

蓝牙全量写入使用已修复事务 ID 的构建；随后 0.2.0 补入失去写入进程后的恢复修复，此分支由 22 项设备端脚本回归覆盖，未额外做物理断电实验。
