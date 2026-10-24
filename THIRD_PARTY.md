# 第三方来源与许可

本项目自行编写的代码、脚本和文档采用根目录的 [MIT License](LICENSE)。第三方材料继续适用其原有许可；本项目的 MIT 声明不改变这些许可。以下记录区分实现参考、随应用打包的组件和系统已有工具。

## 固件、协议及诊断参考

| 项目 | 本项目中的用途 | 参考版本与许可 |
| --- | --- | --- |
| [idootop/open-xiaoai](https://github.com/idootop/open-xiaoai) | LX06 固件处理流程、SSH 和 OTA 修改位置；原版镜像的下载来源。对应 `Firmware.swift`、`Support.swift`。 | [bc3396c](https://github.com/idootop/open-xiaoai/tree/bc3396c64e2a435f354eb5cb12a203981f1fe422)，MIT；保留 [版权及许可全文](Licenses/open-xiaoai-MIT.txt)。 |
| [superna9999/pyamlboot](https://github.com/superna9999/pyamlboot) | Amlogic USB 命令、读写帧、状态确认及校验算法参考；本项目使用 Swift/C 实现，不打包 Python 程序。对应 `USB.swift`、`USBBridge.c`。 | [d2857f4](https://github.com/superna9999/pyamlboot/tree/d2857f4371bcdb7a90d885f24987e03b6d647a8a)。`pyamlboot/pyamlboot.py` 为 Apache-2.0 OR MIT，`pyamlboot/optimus.py` 为 GPL-2.0 OR MIT；采用其 MIT 选项，保留 [版权及许可全文](Licenses/pyamlboot-MIT.txt)。 |
| [duhow/xiaoai-patch](https://github.com/duhow/xiaoai-patch) | 分区布局和固件维护资料参考；未将其实现复制或打包。 | 上游 [LICENSE](https://github.com/duhow/xiaoai-patch/blob/master/LICENSE) 为 GPL v3；本项目未记录当时阅读的提交号。 |
| [yangfl/amlogic-update](https://github.com/yangfl/amlogic-update) | USB 命令格式及 [PROTOCOL.md](https://github.com/yangfl/amlogic-update/blob/master/PROTOCOL.md) 参考；未将其实现或旧版 `update` 可执行文件复制、链接或打包。 | 本次核对根目录未发现 LICENSE 文件，不将其标为 MIT；未记录当时阅读的提交号。 |
| [khadas/u-boot](https://github.com/khadas/u-boot/tree/khadas-vims-v2015.01) | 分析冷启动 USB 烧录窗口、`update` 参数和计时逻辑，辅助实机启动诊断；未复制或打包这些实现，也不替换音箱 bootloader。 | `khadas-vims-v2015.01` 分支中的 `drivers/usb/gadget/v2_burning/v2_usb_tool/optimus_core.c`、同目录 `usb_pcd.c`、`common/main.c`、`lib/time.c`，所阅读文件标注 GPL-2.0-or-later。 |
| [BlueZ](https://github.com/bluez/bluez) | 分析 RFCOMM 终端初始化清空缓冲的行为，定位 SSH 首包竞态。Mac 端代理对应 `Sources/XiaoaiBluetoothProxy/main.m`；Linux 端调用音箱已有的 `rfcomm`。 | [5.37 / tools/rfcomm.c](https://github.com/bluez/bluez/blob/5.37/tools/rfcomm.c)，GPL-2.0-or-later；源码仅用于诊断参考，未随 Mac 应用打包。 |

原版 LX06 1.94.13 镜像来自 [open-xiaoai release](https://github.com/idootop/open-xiaoai/releases/tag/LX06_1.94.13)，由工具另行下载并核对固定 SHA-256。小米固件、设备备份和本机生成的定制固件不包含在 Git 仓库或 Mac 应用包中，其权利归各自权利人。定制操作在用户本地执行。

## 随 Mac 应用打包的组件

以下版本来自 0.2.0 本地构建的 `Contents/Resources/Licenses/*/SOURCE.json`。后续构建以实际应用包中的记录为准。

| 项目 | 0.2.0 构建版本 | 用途及打包方式 | 许可 |
| --- | --- | --- | --- |
| [libusb](https://github.com/libusb/libusb) | 1.0.30 | USB C API；动态库，供 `USBBridge` 使用。 | LGPL-2.1-or-later |
| [SquashFS Tools](https://github.com/plougher/squashfs-tools) | 4.7.5 | `unsquashfs`、`mksquashfs` 独立进程，用于读取、检查及重建镜像。 | GPL-2.0-or-later |
| [LZO](https://www.oberhumer.com/opensource/lzo/) | 2.10 | SquashFS 工具的压缩动态库依赖。 | GPL-2.0-or-later |
| [LZ4](https://github.com/lz4/lz4) | 1.10.0 | SquashFS 工具的压缩动态库依赖。 | 库为 BSD-2-Clause |
| [XZ / liblzma](https://github.com/tukaani-project/xz) | 5.8.4 | 打包 liblzma 动态库。 | liblzma 为 0BSD；XZ 包中其他文件的许可见其 COPYING。 |
| [Zstandard](https://github.com/facebook/zstd) | 1.5.7（Homebrew revision 1） | SquashFS 工具的压缩动态库依赖。 | 主库 BSD-3-Clause OR GPL-2.0-only；包内其他材料还含 BSD-2-Clause、MIT，详见随包声明。 |

`scripts/package.py` 从本机 Homebrew 安装中收集可执行文件和动态库，重定位依赖路径并签名。组件采用 Homebrew 的构建配方及其补丁；0.2.0 的 SquashFS 配方含 Darwin `struct stat` 字段修复。动态库保留为可替换文件，替换后可重新签名。

更新后的打包脚本会在应用包中包含：

- `Contents/Resources/LICENSE`：本项目 MIT 许可。
- `Contents/Resources/THIRD_PARTY.md`：本说明。
- `Contents/Resources/Licenses/References/`：保留的参考项目版权及许可文本。
- `Contents/Resources/Licenses/<formula>/`：组件自带的 COPYING、LICENSE、AUTHORS 等文件。
- 各组件的 `SOURCE.json`：构建时版本、上游源码归档 URL、归档校验值和 Homebrew 许可元数据。

Git 仓库保存项目源码，`dist/` 不提交。GitHub Release 提供应用压缩包及 `XiaoaiWorkbench-0.2.0-ThirdPartySources.tar.gz`，后者包含对应的上游源码归档、许可声明、Homebrew 配方及使用的补丁。组件构建步骤见归档内的 README、INSTALL 和配方，应用打包及动态库路径调整步骤见本项目 `scripts/package.py`。第三方组件继续适用各自条款。

## 系统工具与开发工具

- macOS 的 SwiftUI、AppKit、Foundation、Network、IOKit、IOBluetooth、CoreFoundation 由系统/SDK 提供；应用调用 `/usr/bin/ssh`、`ssh-keygen` 等已有工具，不另行打包 OpenSSH。
- 音箱侧使用已有的 Linux、BusyBox、Dropbear、BlueZ、`fw_env`、`mtd` 和 UCI。OTA agent 是本项目脚本，不分发这些系统组件的源码或二进制。
- [Homebrew](https://github.com/Homebrew/brew) 用于安装构建依赖；Swift、Python、Xcode 工具用于构建和测试。
- [Capstone](https://github.com/capstone-engine/capstone) 5.0.9 曾用于本地 bootloader 反汇编诊断，未随项目或应用打包。

感谢以上项目及贡献者提供实现、协议资料和工具。新增依赖或参考实现时，应同步更新此清单并保留相应上游版权声明。
