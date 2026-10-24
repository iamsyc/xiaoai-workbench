import SwiftUI
import XiaoaiCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var confirmFlash = false
    @State private var confirmRestore = false
    @State private var confirmReboot = false
    @State private var confirmOTA = false
    @State private var confirmOTARollback = false
    private let accent = Color(red: 0.12, green: 0.52, blue: 0.44)

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 38)).foregroundStyle(accent)
                    Text("小爱工作台").font(.title2.weight(.semibold))
                    Text("LX06 · 1.94.13").font(.caption.monospaced()).foregroundStyle(.secondary)
                }.padding(.horizontal, 18).padding(.top, 20)
                List(AppModel.Section.allCases, selection: $model.selected) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 6) {
                    Label("本机运行", systemImage: "desktopcomputer")
                    Text("专用密钥保存在本机\n固件和备份均可导出")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(18)
            }.navigationSplitViewColumnWidth(210)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if let error = model.error {
                            GroupBox {
                                Label {
                                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                } icon: { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                                .padding(6)
                            }
                        }
                        switch model.selected {
                        case .device: deviceView
                        case .firmware: firmwareView
                        case .verify: verifyView
                        case .logs: logsView
                        case .ota: otaView
                        }
                    }.padding(30).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
                }
                Divider()
                HStack(spacing: 12) {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.error == nil ? "circle.dotted" : "exclamationmark.circle").foregroundStyle(.secondary) }
                    Text(model.status).font(.callout).lineLimit(2)
                    Spacer()
                    if let progress = model.progress { Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                }.padding(.horizontal, 24).padding(.vertical, 14)
                if let progress = model.progress { ProgressView(value: progress).tint(accent).accessibilityLabel("当前操作进度") }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .onChange(of: model.host) { _, _ in
            model.verified = false
            model.rebootVerified = false
            model.otaState = nil
        }
        .onChange(of: model.otaBluetooth) { _, _ in model.otaState = nil }
        .onChange(of: model.bluetoothAddress) { _, _ in model.otaState = nil }
        .frame(minWidth: 980, minHeight: 740)
        .confirmationDialog("写入备用槽位并重启音箱？", isPresented: $confirmOTA) {
            Button("升级并验证", role: .destructive) { model.otaInstall() }
        } message: { Text("先复核备份，再写入备用内核和系统，读回校验后试启动。工作台验证镜像与服务后确认升级；设备端试启动等待 90 秒未确认则重启回退。请保持供电。") }
        .confirmationDialog("回退到此次升级前的槽位？", isPresented: $confirmOTARollback) {
            Button("回退并验证", role: .destructive) { model.otaRollback() }
        } message: { Text("会切换启动槽位并重启。已自动回退的事务仅完成环境收尾。") }
        .confirmationDialog("写入 system0 并启用 root SSH？", isPresented: $confirmFlash) {
            Button("写入并验证", role: .destructive) { model.flash() }
        } message: {
            Text("将写入已核对的最小固件。读回校验通过后，设置 boot0 并保留原启动等待值。原始 system0 与原启动项已保存到所选备份目录。请保持 USB 和电源连接。")
        }
        .confirmationDialog("恢复备份的 system0 与原启动项？", isPresented: $confirmRestore) {
            Button("恢复并验证", role: .destructive) { model.restore() }
        } message: { Text("将使用当前选中的备份。写入后读回核对，再恢复备份记录中的 boot_part 和 bootdelay。") }
        .confirmationDialog("重启音箱并重新验证 SSH？", isPresented: $confirmReboot) {
            Button("重启并复验") { model.verify(reboot: true) }
        } message: { Text("音箱会暂时断开网络。工作台会等待重新上线，并核对启动标识确实发生变化。") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("XIAOAI WORKBENCH").font(.caption.weight(.semibold).monospaced()).tracking(2).foregroundStyle(accent)
            Text(model.selected.rawValue).font(.system(size: 30, weight: .semibold))
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }
    }
    private var subtitle: String {
        switch model.selected {
        case .device: "从连接状态开始，每一步都有结果。"
        case .firmware: "从原版固件生成，只开放所需的 root SSH。"
        case .verify: "以音箱返回的身份、版本和启动结果完成验收。"
        case .ota: "通过 Wi-Fi 升级，蓝牙提供备用连接。保留原槽位用于回退。"
        case .logs: "查看阶段、校验值与错误，保存完整的执行记录。"
        }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.headline)
                content()
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
    private func row(_ title: String, _ value: String, icon: String = "checkmark.circle") -> some View {
        HStack(alignment: .top) {
            Label(title, systemImage: icon).foregroundStyle(.secondary)
            Spacer(minLength: 20)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.callout)
    }
    private var deviceView: some View {
        VStack(spacing: 18) {
            card("01  连接主板 USB") {
                Text("拆开 LX06，使用主板上的 Micro USB 数据接口连接 Mac。点击检测后先检查现有连接；出现上电提示时再给音箱断电上电，工作台最多等待 25 秒。握手成功后保持供电和数据线连接。")
                    .foregroundStyle(.secondary)
                if let device = model.device {
                    row("USB 阶段", "U-Boot · \(device.protocolVersion)")
                    row("硬件 board_id", device.environment.boardID)
                    row("当前启动项", device.environment.bootPart)
                    row("启动等待", device.environment.bootDelay.map { "\($0) 秒" } ?? "使用设备默认值")
                } else {
                    row("连接状态", "等待检测", icon: "cable.connector")
                }
                Button("检测 USB 设备", systemImage: "cable.connector", action: model.detect)
                    .buttonStyle(.borderedProminent).disabled(model.busy)
            }
            card("02  保存原始系统") {
                Text("读取 system0 的完整 40 MiB 内容和启动环境，落盘后重新核对。只有与原版 1.94.13 一致的备份可用于首次刷入。")
                    .foregroundStyle(.secondary)
                if let backup = model.backup {
                    row("备份状态", backup.isStock ? "原版 1.94.13，核对通过" : "已备份，内容与原版基线不同")
                    Text(backup.directory.path).font(.caption.monospaced()).textSelection(.enabled)
                }
                HStack {
                    Button("创建备份", systemImage: "externaldrive.badge.plus", action: model.createBackup)
                        .disabled(model.busy || model.device == nil)
                    Button("打开已有备份", action: model.openBackup).disabled(model.busy)
                    if let backup = model.backup { Button("在 Finder 中显示") { model.show(backup.directory) } }
                    Spacer()
                    Button("恢复备份", role: .destructive) { confirmRestore = true }
                        .disabled(model.busy || model.device == nil || model.backup == nil)
                }
            }
            card("03  写入并核对") {
                row("原始系统备份", model.backup?.isStock == true ? "已就绪" : "待完成", icon: "externaldrive")
                row("最小固件", model.firmware != nil ? "已生成并核对" : "前往「最小固件」制作", icon: "shippingbox")
                Text("只写 system0。核对写入内容后再保存启动项，随后进入 SSH 验证。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("刷入最小固件", systemImage: "arrow.down.to.line") { confirmFlash = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.device == nil || model.backup?.isStock != true || model.firmware == nil)
            }
        }
    }
    private var firmwareView: some View {
        VStack(spacing: 18) {
            card("LX06  /  1.94.13") {
                row("原版来源", "open-xiaoai · LX06_1.94.13", icon: "shippingbox")
                Text(LX06.originalHash).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text("制作时下载并校验原版镜像。已有原版文件可直接导入，之后可离线构建。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("制作最小固件", systemImage: "hammer", action: model.build)
                        .buttonStyle(.borderedProminent)
                    Button("导入原版镜像", action: model.importOriginal)
                }.disabled(model.busy)
            }
            card("这份固件做什么") {
                Label("持续开启系统已有的 SSH 服务", systemImage: "terminal")
                Label("使用本机生成的专用 RSA 密钥，关闭密码登录", systemImage: "key")
                Label("关闭系统自动更新，保留当前补丁", systemImage: "arrow.triangle.2.circlepath")
                Divider()
                Text("音频库、录音配置、PAM、root 密码与串口认证保持原样。构建后逐文件核对内容和 Linux 元数据。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let firmware = model.firmware {
                card("输出镜像已核对") {
                    row("大小", (try? firmware.file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "已生成")
                    Text("SHA-256\n\(firmware.hash)").font(.caption.monospaced()).textSelection(.enabled)
                    Text(firmware.changedFiles.joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
                    HStack {
                        Button("显示镜像与修改清单") { model.show(firmware.file) }
                        Button("前往设备刷写") { model.selected = .device }
                    }
                }
            }
        }
    }
    private var verifyView: some View {
        VStack(spacing: 18) {
            card("音箱重新上电后验证") {
                Text("USB 刷写完成后，拔掉 USB 和电源，再接通电源。等待音箱联网，在路由器或米家中查看它的局域网 IP。")
                    .foregroundStyle(.secondary)
                TextField("音箱 IPv4 地址，例如 192.168.31.227", text: $model.host)
                    .textFieldStyle(.roundedBorder).onSubmit { if !model.busy { model.verify() } }
                    .disabled(model.busy).accessibilityLabel("音箱 IPv4 地址")
                HStack {
                    Button("验证 root SSH", systemImage: "checkmark.shield") { model.verify() }
                        .buttonStyle(.borderedProminent).disabled(model.busy || !Workbench.validIP(model.host))
                    Button("复制 SSH 命令", action: model.copySSH).disabled(model.busy)
                    Button("重启并复验", systemImage: "arrow.clockwise") { confirmReboot = true }
                        .disabled(model.busy || !model.verified)
                }
            }
            card("验收结果") {
                row("root 身份", model.verified ? "uid=0，已核对" : "等待验证", icon: "person.badge.key")
                row("设备和固件", model.verified ? "LX06 · 1.94.13 · \(model.verifiedBootPart)" : "等待验证", icon: "hifispeaker")
                row("重启后可用", model.rebootVerified ? "已通过，启动标识发生变化" : "等待重启复验", icon: "arrow.clockwise")
            }
            card("专用 SSH 密钥") {
                Text("密钥用于这份最小固件的 root 登录。请保留应用数据目录，迁移电脑时一并备份私钥。")
                    .foregroundStyle(.secondary)
                Text(model.paths.key.path).font(.caption.monospaced()).textSelection(.enabled)
                Button("显示应用数据目录") { model.show(model.paths.root) }
            }
        }
    }
    private var otaView: some View {
        VStack(spacing: 18) {
            card("01  连接与状态") {
                Picker("传输方式", selection: $model.otaBluetooth) {
                    Text("Wi-Fi").tag(false)
                    Text("蓝牙备用").tag(true)
                }.pickerStyle(.segmented).disabled(model.busy)
                TextField("音箱 IPv4 地址", text: $model.host).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("OTA 音箱 IPv4 地址").disabled(model.busy)
                if model.otaBluetooth {
                    TextField("已配对音箱的蓝牙地址", text: $model.bluetoothAddress).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("音箱蓝牙地址").disabled(model.busy)
                    Text("蓝牙沿用已记录的 SSH 主机身份，IP 仅用作主机密钥索引。传输整个固件耗时较长。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("查询 OTA 状态", action: model.otaCheck).disabled(model.busy || !model.otaConnectionValid)
                if let state = model.otaState {
                    row("运行槽位", state.bootPart)
                    row("事务阶段", state.phase)
                    if let job = state.job { Text(job).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            card("02  备份与升级包") {
                Text("备份两个内核、两个系统的前 40 MiB 及启动环境。system1 额外的 128 KiB 尾部不包含在逻辑镜像备份中。")
                    .font(.callout).foregroundStyle(.secondary)
                if let url = model.otaBackupURL { Text(url.path).font(.caption.monospaced()).textSelection(.enabled) }
                HStack {
                    Button("无线备份", action: model.otaBackup).disabled(!model.otaConnectionValid)
                    Button("选择已有 OTA 备份") { model.chooseOTADirectory(package: false) }
                }.disabled(model.busy)
                Divider()
                Text("先在「最小固件」制作当前版本，再使用 OTA 备份中的内核生成配套升级包。")
                    .font(.callout).foregroundStyle(.secondary)
                if let url = model.otaPackageURL { Text(url.path).font(.caption.monospaced()).textSelection(.enabled) }
                HStack {
                    Button("生成 OTA 包", action: model.otaBuildPackage).disabled(model.firmware == nil || model.otaBackupURL == nil)
                    Button("选择已有 OTA 包") { model.chooseOTADirectory(package: true) }
                }.disabled(model.busy)
            }
            card("03  升级与回退") {
                Text("写入备用槽位并读回校验，保留当前槽位。试启动进入系统后有 90 秒确认窗口；关闭工作台不会停止设备端写入或回退计时。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("升级并验证", systemImage: "arrow.up.circle") { confirmOTA = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || !model.otaConnectionValid || model.otaPackageURL == nil || model.otaBackupURL == nil)
                    Button("确认当前试启动", action: model.otaConfirm)
                        .disabled(model.busy || model.otaState?.phase != "trial")
                    Button("回退原槽位", role: .destructive) { confirmOTARollback = true }
                        .disabled(model.busy || !["trial", "committed", "rolled_back"].contains(model.otaState?.phase ?? ""))
                }
                Text("若系统在启动回退计时器前卡住，需要断电重启触发引导回退；引导程序或两个槽位同时损坏仍需 USB 恢复。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var logsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(model.logs.count) 条记录").foregroundStyle(.secondary)
                Spacer()
                Button("导出执行记录", systemImage: "square.and.arrow.up", action: model.exportLogs)
            }
            Text(model.logs.joined(separator: "\n\n"))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
