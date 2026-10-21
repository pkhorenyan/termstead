import Foundation

/// TermsteadRDP.xpc: FreeRDP, apart from the app. Each XPC connection is one
/// remote desktop, all of them in this one process: launchd gives an app one
/// instance of a service (`_MultipleInstances` is WebKit's alone; tried, and
/// ignored). A crash here ends every remote desktop, and nothing else.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = RDPService.engineInterface
        connection.remoteObjectInterface = RDPService.clientInterface
        let engine = RDPEngine(connection: connection)
        connection.exportedObject = engine
        // The tab closed, or the app went away: nothing is left to draw for.
        connection.invalidationHandler = { engine.disconnect() }
        connection.interruptionHandler = { engine.disconnect() }
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
