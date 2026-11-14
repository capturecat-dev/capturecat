// A stand-in Mac for driving the iOS app in the Simulator: the REAL Mac
// WirelessServer, advertised on Bonjour with the mock API's link key
// (Tests/mock_api.py serves key bytes 0x00…0x1f). Prints every phone change
// and "Continue on Mac" request; with --request-after N it asks the phone to
// start a broadcast N seconds after its app connects.
import Foundation

let args = CommandLine.arguments
let requestAfter = args.firstIndex(of: "--request-after").flatMap { Double(args[$0 + 1]) }
let link = WirelessLink(key: Data((0..<32).map { UInt8($0) }))!
let server = WirelessServer(link: link, macID: UUID().uuidString.lowercased(), macName: "Studio Mac (test)")
nonisolated(unsafe) var requested = false
server.onPhonesChanged = { phones in
    for p in phones {
        print("PHONE \(p.name) app=\(p.hasApp) broadcast=\(p.hasBroadcast) streaming=\(p.isStreaming)")
        if p.hasApp, let delay = requestAfter, !requested {
            requested = true
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                print("REQUEST-BROADCAST sent=\(server.requestBroadcast(from: p.deviceID))")
            }
        }
    }
    fflush(stdout)
}
server.onOpenProject = { id, phone in print("OPEN-PROJECT \(id) from \(phone)"); fflush(stdout) }
try! server.start(advertise: true)
print("FAKE-MAC up keyID=\(link.keyID)"); fflush(stdout)
dispatchMain()
