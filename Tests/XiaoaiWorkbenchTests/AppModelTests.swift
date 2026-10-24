import Foundation
import Testing
import XiaoaiCore
@testable import XiaoaiWorkbench

struct AppModelTests {
    @MainActor @Test(arguments: [false, true])
    func failedVerificationClearsPreviousRebootResult(reboot: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(paths: LocalPaths(root: directory, tools: directory))
        model.host = "192.168.31.227"
        model.verified = true
        model.rebootVerified = true

        // The isolated directory has no SSH key, so failure happens before any network access.
        model.verify(reboot: reboot)
        #expect(!model.verified)
        #expect(!model.rebootVerified)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.busy && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.busy)
        #expect(model.error == "本机尚无专用 SSH 密钥，请先制作固件。")
        #expect(!model.verified)
        #expect(!model.rebootVerified)
    }
}
