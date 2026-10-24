# AI agent CLI

可执行文件：`dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench`。
无参数启动 GUI；`--cli` 进入无窗口、无交互输入的命令模式。所有路径参数接受绝对路径，包含空格时按单个参数传入。不要通过拼接 Shell 字符串调用，优先使用进程参数数组。

```sh
dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench --cli --help
dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench --cli paths
```

## 命令

| 命令 | 必需参数 | 行为 |
| --- | --- | --- |
| `paths` | 无 | 返回数据目录和打包工具目录，不创建目录 |
| `prepare-original` | 无 | 获取并校验原版 1.94.13，已缓存时直接验证 |
| `import-original` | `--file FILE` | 校验并导入本地原版固件 |
| `build` | 无 | 制作最小固件，返回镜像路径、清单路径和 SHA-256 |
| `check-backup` | `--backup DIR` | 校验本地备份及启动环境，不访问 USB |
| `detect` | 无 | 打开 USB、握手、读取当前启动环境 |
| `backup` | `--output NEW_DIR` | 同一会话内检测并完整备份 system0 |
| `flash` | `--firmware FIRMWARE_JSON --backup DIR --confirm-write` | 校验备份、密钥和镜像，写入并读回核对，保存 boot0、保留原 bootdelay |
| `restore` | `--backup DIR --confirm-write` | 写回备份，读回核对并恢复原启动项 |
| `verify-ssh` | `--host IPV4` | 核对 root、LX06、1.94.13、boot0 和启动 UUID |
| `verify-bluetooth` | `--host KNOWN_IPV4 --address BLUETOOTH_MAC` | 经 RFCOMM 通道 23 完成同样的 root SSH 核对 |
| `reboot-verify` | `--host IPV4 --confirm-reboot` | 重启，等待启动 UUID 改变并复验 SSH |
| `ssh-command` | `--host IPV4` | 返回 SSH 命令字符串，不建立连接 |
| `observe` | `--output NEW_DIR` | 被动记录系统 USB 与内核日志 120 秒，不发送设备请求 |
| `diagnose` | `--output NEW_DIR` | 系统监测加检测备份，失败后继续观察至 120 秒窗口结束 |

`detect`、`backup`、`flash`、`restore` 接受 `--timeout SECONDS`，默认 120，范围 1 至 600。它仅控制 USB 等待上限，传输另有自身超时。

`paths`、`prepare-original`、`import-original`、`build`、`flash`、`verify-ssh`、`reboot-verify`、`ssh-command` 接受 `--data-dir DIR`。默认为当前用户的 `Library/Application Support/XiaoaiWorkbench`，与 GUI 共用缓存和密钥。生成固件和 SSH 验证必须使用同一数据目录。

`build` 接受 `--original FILE`，可直接从本地原版制作，避免下载。`build` 和 `paths` 接受 `--tools-dir DIR`；打包应用默认使用包内工具。

`--firmware` 指向 `build` 返回的 `manifest`，即 `firmware.json`，该文件内的镜像 URL 必须仍然有效。备份参数指向包含 `backup.json` 和 `system0.bin` 的目录。

## 输出协议

除了帮助输出，`--cli` 的正常结束始终在 stdout 输出一个 JSON 对象，以换行结束。stderr 为 JSONL 进度，不能与 stdout 合并后作为单个 JSON 解析。没有进度的本地查询允许 stderr 为空。

```json
{"schemaVersion":1,"command":"paths","ok":true,"data":{"dataDirectory":"/example/data","toolsDirectory":"/example/tools"}}
```

```json
{"schemaVersion":1,"command":"restore","ok":false,"error":{"code":"invalid_arguments","message":"此命令会写入音箱，必须显式提供 --confirm-write。"}}
```

```json
{"schemaVersion":1,"type":"progress","command":"backup","message":"正在读取 system0（40 MiB）","fraction":0.5}
```

可选字段缺失表示不适用或未设置。`bootDelay` 缺失表示设备未设置该变量，不代表零。`isStock` 为布尔值。stdout 不包含环境全文或 SSH 原始输出。

| 退出码 | 含义 |
| --- | --- |
| `0` | 操作完成，`ok=true` |
| `64` | 参数错误或缺少显式确认，`error.code=invalid_arguments`，尚未执行操作 |
| `1` | 操作失败，`error.code=operation_failed` |

被外部信号终止或进程崩溃时，可能没有最终 JSON；agent 必须同时检查进程状态和结果，不能从最后一条进度推断成功。诊断失败时，日志保存在请求的输出目录；备份失败留下的文件不应当作有效备份，必须通过 `check-backup` 验证。

## 推荐调用流程

1. 用 `paths` 确认数据目录，用 `build` 制作固件并保存返回的清单路径。
2. 直接运行 `backup --output NEW_DIR`。它会先检查当前连接，需要上电时输出提示。物理断电上电仍需操作者完成。
3. 校验返回的 `isStock` 和备份摘要。需要详细 USB 排查时使用 `diagnose`。
4. 在用户已经授权刷写后，运行 `flash` 并显式传入 `--confirm-write`。此参数表示调用者的授权声明，不能代替用户授权。
5. `flash` 或 `restore` 成功返回 `requiresPowerCycle=true`，表示 USB 写入和校验完成，仍需按提示拔掉 USB 和电源、重新上电，再进行 SSH 验证。
6. 用 `verify-ssh` 验收；用户授权重启后再使用 `reboot-verify --confirm-reboot`。

每个进程自行建立 USB 会话，命令结束时释放连接。一次只运行一个设备操作，关闭其他正在访问音箱的 GUI 或刷机工具。命令不会隐式进入刷写或重启步骤，失败后也不会自动重试写入。

## 蓝牙 SSH

蓝牙通道使用 RFCOMM 承载 SSH，音箱端转发到本机 Dropbear。它不依赖蓝牙 PAN 或 Wi-Fi 数据传输。
新构建固件在 `/etc/rc.local` 启动要求蓝牙认证与链路加密的 RFCOMM 监听，SSH 继续校验主机密钥和 root 公钥。
Mac 与音箱须先完成蓝牙配对，并先通过 Wi-Fi SSH 保存音箱主机密钥。

```sh
dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench --cli verify-bluetooth --host 192.168.1.11 --address EC:41:18:6E:AF:06
dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench --cli ssh-command --host 192.168.1.11 --address EC:41:18:6E:AF:06
```

这里 `--host` 用于查找此前已保存的 SSH 主机密钥，实际连接目的地是 `--address` 指定的蓝牙地址。
蓝牙模式强制校验已有主机密钥。`verify-bluetooth` 也接受 `--data-dir`。
随包的 `XiaoaiBluetoothProxy` 是 SSH 的字节流代理，其 stdout 为原始传输数据；agent 应调用工作台的 JSON CLI。
旧的六文件 SSH 固件没有蓝牙开机入口；只有已刷入七文件版本并通过重启验收后，才能将蓝牙作为重启后的独立备用通道。

## 离线验证

`swift test` 使用 USB 替身验证业务流程与 CLI 参数边界。

```sh
python3 scripts/test-cli.py dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench
python3 scripts/test-cli.py dist/XiaoaiWorkbench.app/Contents/MacOS/XiaoaiWorkbench --original .cache/LX06_1.94.13.squashfs
```

第二条在独立临时数据目录中制作真实镜像，检查 JSON 进度与产物摘要，然后清理测试文件。这些测试不会检测 USB、连接 SSH、刷写或重启音箱。

## 无线 OTA

新增 `ota-status`、`ota-backup`、`ota-package`、`ota-install`、`ota-confirm`、`ota-rollback`。网络命令使用 `--host`，可增加 `--address` 切换蓝牙；写入命令要求 `--confirm-write`。完整流程、JSON 状态语义和回退边界见 [Wi-Fi OTA](WIFI-OTA.md)。
