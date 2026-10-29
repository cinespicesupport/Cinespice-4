import SwiftUI

@main
struct CinespiceApp: App {
    @UIApplicationDelegateAdaptor(CinespiceAppDelegate.self) private var appDelegate
    @StateObject private var library: LibraryStore
    @StateObject private var telegram: TelegramClient
    @StateObject private var rangeServer = TelegramRangeServer()

    init() {
        let library = LibraryStore()
        _library = StateObject(wrappedValue: library)
        _telegram = StateObject(wrappedValue: TelegramClient(library: library))
    }
    var body: some Scene {
        WindowGroup {
            TelegramLibraryView()
                .environmentObject(library)
                .environmentObject(telegram)
                .environmentObject(rangeServer)
        }
    }
}
