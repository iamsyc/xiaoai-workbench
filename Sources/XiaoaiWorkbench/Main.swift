import AppKit
import SwiftUI
import XiaoaiCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.writingDevice == true { NSSound.beep(); return .terminateCancel }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor struct WorkbenchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        Window("小爱工作台", id: "main") {
            ContentView(model: model).onAppear {
                delegate.model = model
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: false)
            }
        }.defaultSize(width: 1080, height: 820)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出小爱工作台") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q").disabled(model.writingDevice)
            }
        }
    }
}

@main @MainActor enum Launcher {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.dropFirst().first == "--cli" {
            let cliArguments = Array(arguments.dropFirst(2))
            if cliArguments == ["--help"] {
                FileHandle.standardOutput.write(Data((CLICommand.help + "\n").utf8)); exit(0)
            }
            let (status, response) = await CLICommand.run(cliArguments)
            do { FileHandle.standardOutput.write(try CLICommand.encoded(response)) }
            catch { FileHandle.standardError.write(Data("CLI JSON encoding failed\n".utf8)); exit(1) }
            exit(status)
        }
        if arguments.dropFirst().elementsEqual(["--help"]) {
            FileHandle.standardOutput.write(Data((CLICommand.help + "\n").utf8)); exit(0)
        }
        if arguments.count >= 2, ["--usb-diagnose", "--usb-observe"].contains(arguments[1]) {
            let passive = arguments[1] == "--usb-observe"
            let usage = passive ? USBDiagnosticCommand.observeUsage : USBDiagnosticCommand.usage
            if arguments.count == 3, arguments[2] == "--help" {
                FileHandle.standardOutput.write(Data(usage.utf8)); exit(0)
            }
            guard arguments.count == 3 else {
                FileHandle.standardError.write(Data(usage.utf8)); exit(64)
            }
            do {
                try await USBDiagnosticCommand.run(directory: URL(fileURLWithPath: arguments[2]), passive: passive)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
            }
        }
        if arguments.count == 5, arguments[1] == "--self-check" {
            let paths = LocalPaths(root: URL(fileURLWithPath: arguments[3]), tools: URL(fileURLWithPath: arguments[4]))
            let workbench = Workbench(paths: paths)
            do {
                try await workbench.importOriginal(from: URL(fileURLWithPath: arguments[2]))
                let artifact = try await workbench.buildFirmware { message, _ in
                    FileHandle.standardError.write(Data((message + "\n").utf8))
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                FileHandle.standardOutput.write(try encoder.encode(artifact))
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
            }
        }
        guard arguments.count == 1 else {
            FileHandle.standardError.write(Data("未知参数。使用 --cli --help 查看 CLI 用法。\n".utf8)); exit(64)
        }
        WorkbenchApp.main()
    }
}
