# LX06 本地无线升级

适用当前已取得 root SSH 的 LX06 / 1.94.13。Wi-Fi 和蓝牙 RFCOMM 都传输 SSH，认证使用专用私钥和已记录的主机公钥。蓝牙需要事先完成系统配对；选择蓝牙时 `--host` 只用于 SSH 主机身份索引，无需 Wi-Fi 可达。

## 升级范围

本地升级包包含配套的 `boot.img`、`root.squashfs` 和 `ota.json`。支持的 1.94.13 内核 SHA-256 固定为 `f38a880f0c7e7f12bbaced111d5e210d89a38158d1b26e9fb7b5f60f210442d2`。构建器核对原版来源、镜像内容、密钥及试启动回退入口。

应用上传全部文件后，音箱在本地复核长度与哈希，写入当前槽位的另一组内核和系统，逐个读回校验。两个镜像均通过后才切换启动项。传输失败不会触发写入；上传完成后的写入进程独立于 Mac 的 SSH 会话。

不使用小米云端 OTA 服务。原厂自动升级入口继续禁用。本工具不写 bootloader、DTB 或整个 NAND，也不支持直接导入任意版本的官方升级包。

## 试启动与回退

1. 写入完成后，保存原槽位及独立试启动标记，再切换到新槽位。
2. 引导脚本将 `armed` 改为 `trying`。如果下一次启动仍是 `trying`，切回原槽位，并清零原厂启动失败计数。
3. 新系统的 `rc.local` 启动设备端计时器。90 秒内没有确认就自动重启，下一次引导回退。
4. 正常安装会在新启动标识、root、型号、版本、挂载槽位、运行镜像哈希、计时器进程及蓝牙监听器核对通过后提交。提交后恢复原始 `preboot`。
5. `ota-rollback` 可回退已提交的最近一次升级，也可完成已自动回退事务的环境收尾。

计时器依赖 Linux 启动到 `rc.local`。如果此前内核卡死，需断电重启触发引导回退。引导程序损坏、两个槽位同时损坏或启动环境写入过程中断电导致环境损坏，仍可能需要拆机 USB 恢复。当前设计没有声称提供硬件看门狗或原子冗余环境存储。

启动环境中的 `boot_part` 也由 initramfs 用来选择根分区，因此切换必须涵盖配套内核和系统。原厂 `S95done` 会清零 `boot_failcnt`，本工具使用独立 `xw_ota_state` 确认事务。

## 备份边界

`ota-backup` 读取 boot0/boot1 各 6 MiB、system0/system1 各前 40 MiB 和 64 KiB 启动环境。每个分区分别再次在设备上计算哈希，与传回文件及落盘文件比较。备份期间启动标识必须保持一致。

本机 system1 报告大小为 40 MiB + 128 KiB，最后 128 KiB 读取失败，sysfs 报告一个坏块。前 40 MiB 两次读取一致且可完整解包，备用系统为 1.88.221。备份保留这个明确边界，不能称为完整原始 NAND 备份。

安装前再次检查当前内核和系统与选中备份一致。再次升级到另一槽位前需生成与当前槽位对应的新备份。每次升级覆盖备用槽位，只保留上一次运行系统作为设备内回退点；历史镜像保存在 Mac 备份目录。

## GUI

进入「无线升级」：选择 Wi-Fi 或蓝牙，填写地址，查询状态，创建无线备份；在「最小固件」生成当前固件，再回到「无线升级」生成 OTA 包。也可选择已有的备份和升级包。点击「升级并验证」会执行上传、写入、试启动及确认。程序中断后可重新查询事务，确认试启动或回退。

## CLI

```bash
APP="$PWD/dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench"
"$APP" --cli ota-status --host 192.168.1.11
"$APP" --cli ota-backup --host 192.168.1.11 --output /absolute/path/new-backup
"$APP" --cli build
"$APP" --cli ota-package --firmware /absolute/path/firmware.json \
  --kernel /absolute/path/new-backup/boot0.bin --output /absolute/path/new-package
"$APP" --cli ota-install --host 192.168.1.11 \
  --package /absolute/path/new-package --backup /absolute/path/new-backup --confirm-write
```

所有网络 OTA 命令均接受 `--address EC:41:18:6E:AF:06` 切换蓝牙。蓝牙整包传输耗时较长，文件传输超时上限为 30 分钟。

验收时可用 `ota-install --defer-confirm` 停在试启动阶段。需要提交时执行：

```bash
"$APP" --cli ota-confirm --host 192.168.1.11 --job UUID --confirm-write
"$APP" --cli ota-rollback --host 192.168.1.11 --confirm-write
```

结果以 stdout 中的 JSON `ok` 及 `data.ota.phase` 为准，stderr 为 JSON Lines 进度。退出码 0 表示成功，64 表示参数错误，1 表示操作失败。`trial` 仅代表新系统已上线，`committed` 才代表升级已确认。连接中断后先查询状态，避免重复提交写入。失败写入日志位于音箱 `/tmp/xiaoai-ota/<job>/apply.log`，重启后 tmpfs 日志消失；事务记录保存在 `/data/xiaoai-ota/state`。

## 本地验证

```bash
swift test
python3 scripts/test-ota-agent.py
python3 scripts/test-bluetooth-proxy.py
python3 scripts/test-cli.py dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench
```

设备脚本测试通过隔离命令替身执行实际脚本，覆盖坏包、内核写入失败、系统写入失败、读回不符、环境切换失败、确认条件、显式回退、超时重启及 U-Boot 试启动状态变化，不访问真实音箱。

## macOS 安装与网络授权

本机验收使用 `/Applications/XiaoaiWorkbench.app`。构建产物位于 `dist/XiaoaiWorkbench.app`，使用本机 Apple 开发者证书签名，未发布或公证。安装后通过 GUI 发起 Wi-Fi 连接，系统需要授权时选择允许本地网络；若被拒绝，在系统设置的「隐私与安全 → 本地网络」中调整本应用权限。

GUI 在启动 SSH 前保留一个到音箱 22 端口的 Network.framework 连接，使系统有时间完成网络授权。Apple [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) 说明了命令行和 GUI 的授权归属差异、短命辅助进程可能无法触发提示，以及稳定代码签名要求。实测开发目录中的旧实例收到 `Local network prohibited`；安装完整签名应用后，GUI 连接成功。未修改系统防火墙或全局隐私数据库。
