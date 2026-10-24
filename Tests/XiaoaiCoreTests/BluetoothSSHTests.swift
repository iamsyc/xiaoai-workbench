import Foundation
import Testing
@testable import XiaoaiCore

struct BluetoothSSHTests {
    @Test func validatesAddressAndQuotesProxyPath() throws {
        let proxy = try BluetoothSSH(executable: URL(fileURLWithPath: "/tmp/a b/'$(touch nope)%h/proxy"),
                                     address: "ec:41:18:6e:af:06")
        #expect(proxy.address == "EC:41:18:6E:AF:06")
        #expect(proxy.proxyCommand == "'/tmp/a b/'\\''$(touch nope)%%h/proxy' EC:41:18:6E:AF:06")
        for invalid in ["", "EC:41:18:6E:AF:06;id", "EC:41:18:6E:AF:06\n", "EC:41:18:6E:AF:GG"] {
            #expect(!BluetoothSSH.validAddress(invalid))
        }
    }
}
