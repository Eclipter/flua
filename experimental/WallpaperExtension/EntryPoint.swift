import Foundation
import ExtensionFoundation

@main
struct FluaWallpaperExtension: AppExtension {
    init() {}
    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onConnection: { connection in
            FSConfigureConnection(connection)
        })
    }
}
