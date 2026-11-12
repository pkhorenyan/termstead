import Foundation

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = VNCService.engineInterface
        connection.remoteObjectInterface = VNCService.clientInterface
        let engine = VNCEngine(connection: connection)
        connection.exportedObject = engine
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
