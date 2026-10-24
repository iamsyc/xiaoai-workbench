# 小爱工作台

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

面向小爱音箱 Pro（LX06）、原版固件 1.94.13 的本地 macOS 图形工具。
当前构建针对 Apple Silicon、macOS 27。开发预览版本为 0.2.0。

应用集中完成 USB 检测、system0 备份、最小固件制作、分区写入与读回校验、
启动项保存、SSH root 验证，以及从本机备份恢复。无线升级支持 Wi-Fi 和蓝牙，提供双槽位备份、试启动确认及回退。

## 首次使用需要拆机

**首次 USB 解锁、备份和刷机，需要拆开音箱外壳，使用支持数据传输的 Micro USB 线，将主板内部用于调试和刷机的 USB 接口连接到 Mac。** 音箱电源线需要单独连接；仅接通电源无法进行 USB 检测和刷写。

先连接内部 Micro USB 数据线，再启动工作台检测，按提示给音箱断电上电；此时保留数据线连接。进入刷写后保持电源和数据线连接，直到工具报告写入及读回校验完成。

完成首次刷机并验证无线连接后，可以拔掉内部 USB 数据线、装回外壳，日常通过 Wi-Fi 进行 root SSH、备份和 OTA，蓝牙作为备用通道。需要 USB 恢复时，再拆机连接该接口。操作顺序见下方「使用」。

## 当前验证边界

自动化验证覆盖 USB 协议帧、设备响应失败、短读、读回不符、启动项写入顺序、
损坏备份、SSH 身份检查和不经 Shell 的进程参数传递。
使用真实原版固件构建，并逐文件核对输出的内容与 Linux 元数据。

LX06 实机已捕获 `1b8e:c003` 与 `0-7-0-16-0-0-0-0` 握手响应。
持续监听版本已成功读取启动环境（board_id=1、boot_part=boot0、bootdelay=1）。
2026-10-24 修正 READ_MEDIA 包大小参数后，实机已完整读取 system0 的 640 个
64 KiB 块（40 MiB），备份落盘校验通过，逻辑镜像 SHA-256 匹配原版 1.94.13。
该次重试的 USB 端口位置也发生变化，不能将此前 84% 处掉线唯一归因于参数错误。
2026-10-24 已通过 CLI 刷入最小 SSH 固件，镜像读回 SHA-256 与待刷文件一致，
保存并回读核对 boot0，保留 bootdelay=1。结果与进度见 `.cache/wifi-root-flash.json`
及 `.cache/wifi-root-flash-progress.jsonl`。随后正常启动，已通过 192.168.1.11 验证 root、
LX06、1.94.13 和 boot0；实际内核为 4.9.61。蓝牙 RFCOMM 临时代理也已取得 root SSH，
启动 UUID 与 Wi-Fi 会话一致。蓝牙开机固件现已刷入并读回校验，开机脚本自动启动 RFCOMM 监听。
修复了设备缺少 `nohup` 导致的软件重启失败，以及 RFCOMM 终端初始化清空缓冲与客户端提前发送
SSH 数据之间的竞态。Mac 代理收到服务端首包后才发送客户端数据。验收记录见
[实机验收](docs/device-validation-20261024.md)。
本机没有接入音箱时，工具会报告未检测到设备，禁止备份与刷写。
USB VID/PID 只用于定位 Amlogic 设备；还需读取 U-Boot 环境并核对 LX06 board_id。

## 使用

AI agent 可使用完整 CLI：`XiaoaiWorkbench --cli --help`。支持检测、备份、制作固件、刷写、
恢复和 SSH 验证，stdout 返回 JSON、stderr 输出 JSONL 进度，写入与重启必须显式确认。
命令参数、退出码、调用流程和离线测试见 [CLI.md](docs/CLI.md)。

1. 打开 `dist/XiaoaiWorkbench.app`，进入「最小固件」，点击「制作最小固件」。
   首次下载原版镜像并核对固定 SHA-256，已有文件可选择导入。
2. 拆开 LX06，使用支持数据传输的 Micro USB 线，将主板内部的调试/刷机接口连接到 Mac，音箱电源单独接入。点击「检测 USB 设备」，工具先检查现有连接；出现上电提示时保留数据线连接，再给音箱断电上电，最多等待 25 秒。握手成功后保持供电和数据线连接。
3. 选择备份目录，保存完整 system0 和启动环境。落盘文件必须再次通过校验。
4. 点击「刷入最小固件」，检查确认窗口后执行。写入后读回比较，通过后才保存 boot0，并保留设备原 bootdelay 值（未设置时保持未设置）。
5. 拔掉 USB 与电源，再接通电源。等待音箱联网，输入局域网 IPv4 地址，验证 root SSH。
6. 点击「重启并复验」，核对启动标识确实改变，并再次验证身份、版本和启动项。

制作固件可以独立于 USB 连接执行。只写 system0；boot0、boot1、system1、数据分区、
bootloader 和设备密钥分区不在写入范围内。首次刷入要求备份中的 system0 与原版
1.94.13 精确一致，避免把新 rootfs 与其他版本的目标槽位混用。

## 固件变化

新构建修改以下 7 个文件：

- `etc/init.d/dropbear`：移除正式版 SSH 启动门控和蓝牙模式限制，保留配置校验。
- `etc/config/dropbear`：关闭密码登录，保留 root 公钥认证。
- `etc/dropbear/authorized_keys`：替换为本机生成的专用 RSA 公钥。
- `bin/ota`、`bin/flash.sh`、`etc/init.d/wireless`：阻止自动 OTA 覆盖补丁。
- `etc/rc.local`：启动带蓝牙认证及链路加密的 RFCOMM 通道 23，将 SSH 数据转发至本机端口 22。

音频库、ALSA 配置、PAM、`etc/shadow`、串口认证及其余启动脚本保持原样。
镜像通过 SquashFS 伪文件重建，保留设备节点、链接、时间、权限、UID/GID。
构建后重新读取输出镜像，逐项比对所有文件和元数据。
固件目录包含 `firmware.json`，记录来源校验值、公钥摘要、修改文件和输出校验值。

原版镜像固定来源：
[LX06 1.94.13](https://github.com/idootop/open-xiaoai/releases/tag/LX06_1.94.13)。

```text
317a54909f12b63f22128965bf9005c06435d15f61c4202bb88c4524bf1e2ef4
```

## 本地数据

应用数据位于 `~/Library/Application Support/XiaoaiWorkbench/`。
其中有专用 SSH 私钥、已知主机记录、原版缓存、生成镜像和执行记录。
数据目录权限为 0700；私钥由系统 ssh-keygen 创建。备份存放在用户选择的目录，
包括 `system0.bin` 和 `backup.json`。应用核对备份内容后才允许恢复。

保留应用数据目录及所选备份目录。迁移电脑时需要迁移 SSH 私钥。
「复制 SSH 命令」使用应用自己的已知主机文件，不修改全局 SSH 配置。
SHA-1 RSA 算法仅在这台音箱的 SSH 调用参数内启用，以连接原厂 Dropbear。

## 恢复

重新以 USB 连接并检测设备，打开此前保存的备份，点击「恢复备份」。
工具核对备份 SHA-256 与 board_id，写回 system0，读回验证后恢复原 boot_part、bootdelay。
恢复内容仅限本工具修改的系统分区和两个启动变量。
备份不包含用户数据、bootloader、boot0/boot1 内核，也不承诺修复其他方式造成的损坏。

USB 操作采用 U-Boot 的 `env export -t`、`upload`、`download` 和 `saveenv`。
启动环境先导出到 RAM 的 0x01080000 地址，再通过 USB 读取。
若固件的 U-Boot 不支持这些命令，检测即停止，不更改持久化内容。
写入不会自动重试。启动项只会在镜像读回校验通过后保存。

## USB 只读诊断

先检查当前端口状态时，可以运行两分钟被动诊断，无需断电：

```bash
dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench \
  --usb-observe "$PWD/.cache/USB-Observe-next"
```

这个入口只读 IORegistry 并订阅系统通知，不创建 libusb 上下文，不打开 USB 设备，
不执行 identify、环境读取或备份。它记录设备和端口的首次发布、驱动匹配、移除事件，
以及每 250 毫秒采样的端口状态、连接次数、地址分配失败、枚举失败和过流计数。
起始和结束保留完整的筛选后快照，中间只记录变化及每 10 秒心跳。
计数属于该注册表实例的累计值，比较时应使用相同 registryID；缺失字段表示未知。
`port-status` 和电源状态保留驱动原始数值，不据此推断供电电压或设备启动模式。

两个诊断入口都会生成 `kernel-usb.ndjson`、`kernel-usb.stderr` 和 `usb-diagnostics.jsonl`。
内核日志由独立的系统 `log stream` 进程采集，不修改系统日志级别配置。
日志中记录进程启动、退出或不可用状态；空日志不能证明底层没有发生电气活动。
系统日志可能包含设备标识，整个输出目录应作为本地诊断资料保管。
首次发布事件发生在驱动匹配之前，但仍然依赖内核创建 IOService，无法替代电气测量。

排查上电后连接很快消失的问题时，使用应用内置的诊断入口。
先启动下面的命令，出现等待设备的上电提示后，保持 USB 数据线连接，给音箱断电上电。
输出目录必须是新目录。

```bash
dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench \
  --usb-diagnose "$PWD/.cache/USB-Diagnosis-next"
```

等待设备最多 120 秒，按约 100 毫秒间隔尝试连接。首次有效识别后停止轮询，
在同一连接上立即读取启动环境并备份 system0，不再重新打开设备或重复 identify。
整轮检测共用一个 libusb 上下文，失败重试不重建监听线程或清空设备缓存。
macOS IOKit 通知持续记录 `usb.device.present`、`usb.device.arrived` 和
`usb.device.removed`，包含注册表 ID、VID/PID 和端口位置。接入、移除事件不依赖定时采样。
已有连接会直接握手；看到「正在等待 USB 设备」的上电提示后再操作音箱电源。
握手成功后保持供电和数据线连接。设备事件也会实时输出到诊断控制台。
环境读取或后续传输失败即停止，记录失败阶段；该入口不执行分区写入或保存启动项。
握手、环境读取或备份失败后，系统 USB 监测和内核日志采集均继续至本轮 120 秒窗口结束，
不再发送设备请求。任务取消时结束等待；成功时在备份完成后结束。

输出包含 `usb-diagnostics.jsonl`，成功时还有 `Backup/system0.bin` 与 `Backup/backup.json`。
日志记录时间、毫秒偏移、打开失败阶段、端点、请求参数、底层返回码和耗时，
以及识别响应、命令状态、备份摘要。日志不记录私钥、环境变量全文或固件内容。
环境成功读取后额外记录本次会话的 `reboot_mode`、`identifyWaitTime`、启动分区等白名单字段。
这份环境值不等同于直接读取 SoC 复位原因寄存器；连接失败时会明确记录启动环境不可用，
不会从历史备份填补本次状态。被动入口始终不读取启动环境。
读取采用 64 KiB 数据块，READ_MEDIA 的包大小参数固定为 4096，
并核对设备返回的 16 字节传输头中的声明长度。
每块记录偏移、声明长度和实际传输字节数；失败时记录已完成的字节数。
日志先保存在内存，会话结束后一次落盘，以减少文件写入对握手时序的影响。
输出目录权限为 0700，日志为 0600。

`python3 scripts/test-bluetooth-proxy.py` 使用延迟就绪的 RFCOMM 替身运行真实代理代码，
检查客户端发送时机与按 MTU 分块后的字节完整性，不访问蓝牙硬件。

`sh scripts/test-usb-bridge.sh` 使用 libusb 替身检查 C 层的上下文生命周期，
覆盖等待设备、关闭句柄和接口占用失败后的释放顺序，不访问真实 USB 设备。

诊断结果以环境读取和备份完成为准。单次 identify 成功不能证明连接能持续保持，
也不能证明 NAND 读写已通过验证。

## 开发与打包

需要完整 Xcode、Swift 6、Homebrew 的 libusb 1.0 和 squashfs。
Python 3 仅用于开发时打包，应用运行不需要 Python、Docker 或 Homebrew。

```bash
brew install libusb squashfs
swift test
python3 scripts/package.py
```

当前机器的默认开发目录指向 Command Line Tools，且 Xcode.app 链接已经失效。
本项目验证使用以下环境变量指定完整 Xcode，不修改系统设置：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer
swift test
python3 scripts/package.py
```

打包脚本收集非系统动态依赖，改写为包内相对路径，并使用本机 Apple 开发者证书签名。
打包需要有效的 Apple Development 或 Developer ID Application 证书，可用 `XIAOAI_SIGN_IDENTITY` 指定；默认选取本机首个有效证书。`dist/SHA256.json` 列出包内文件校验值。本地构建不涉及发布、上传或公证。
开发时可运行真实镜像自检，参数依次为原版文件、独立测试数据目录、工具目录：

```bash
dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench --self-check \
  "$PWD/.cache/LX06_1.94.13.squashfs" \
  "$PWD/.cache/QA With Spaces" \
  "$PWD/dist/XiaoaiWorkbench.app/Contents/Resources/Tools"
```

此自检只处理本地文件，不会检测或写入音箱。

## 源码

- `Sources/USBBridge`：libusb 1.0 的最小 C 接口。
- `Sources/XiaoaiCore/USB.swift`：USB 帧、命令、传输确认和环境读取。
- `Sources/XiaoaiCore/Firmware.swift`：最小固件制作与全部文件核对。
- `Sources/XiaoaiCore/Workbench.swift`：备份、刷写、恢复与 SSH 验收。
- `Sources/XiaoaiWorkbench`：SwiftUI 界面与应用状态。
- `Tests/XiaoaiCoreTests`：协议和操作边界测试。

上游来源、协议参考和随包许可证见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 许可证与致谢

本项目自行编写的代码、脚本和文档采用 [MIT License](LICENSE)，Copyright (c) 2026 iamsyc。
第三方代码、工具、库及固件保留各自的版权和许可证。

感谢 [idootop/open-xiaoai](https://github.com/idootop/open-xiaoai)、
[superna9999/pyamlboot](https://github.com/superna9999/pyamlboot)、
[duhow/xiaoai-patch](https://github.com/duhow/xiaoai-patch)、
[yangfl/amlogic-update](https://github.com/yangfl/amlogic-update)、
[khadas/u-boot](https://github.com/khadas/u-boot) 和
[BlueZ](https://github.com/bluez/bluez) 提供的固件工作流、协议及诊断参考。
应用还使用 libusb、SquashFS Tools、LZO、LZ4、XZ/liblzma 和 Zstandard。
具体用途、参考版本、分发方式及许可信息见 [第三方来源与许可](THIRD_PARTY.md)。

## Wi-Fi OTA 与蓝牙备用

已 root 的 LX06 可在「无线升级」通过 SSH 备份双槽位并升级备用槽位，支持试启动确认和回退。GUI 和 CLI 共用事务实现。操作、备份范围及恢复限制见 [无线升级说明](docs/WIFI-OTA.md)。

本机备份、升级及故障回退证据见 [2026-10-24 OTA 验收记录](docs/ota-validation-20261024.md)。
