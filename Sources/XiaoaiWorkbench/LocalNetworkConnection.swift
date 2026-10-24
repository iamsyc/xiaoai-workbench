import Foundation
import Network
import XiaoaiCore

/// Keep the app's connection alive while macOS presents local-network consent.
/// A short-lived ssh child can exit before that prompt is displayed (Apple TN3179).
@MainActor final class LocalNetworkConnection {
    private var connection: NWConnection?
    private var completion: CheckedContinuation<Void, any Error>?
    private var timeout: Task<Void, Never>?

    func check(host: String) async throws {
        guard Workbench.validIP(host) else { throw WorkbenchError("请输入有效 IPv4 地址。") }
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 22, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready: self?.finish(nil)
                    case .failed(let error): self?.finish(error)
                    default: break // .waiting retains the connection while the user grants access.
                    }
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                self?.finish(WorkbenchError("无法连接音箱 SSH。请确认音箱在线，并在「系统设置 → 隐私与安全 → 本地网络」允许小爱工作台。"))
            }
        }
    }
    private func finish(_ error: (any Error)?) {
        guard let completion else { return }
        self.completion = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        timeout?.cancel(); timeout = nil
        if let error { completion.resume(throwing: error) } else { completion.resume() }
    }
}
