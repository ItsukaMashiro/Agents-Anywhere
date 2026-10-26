import SwiftUI

@main
struct AgentsAnywhereApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.storageKey) private var appearanceValue = AppAppearance.system.rawValue

    init() {
        AppFontRegistry.registerBundledFonts()
        AADiag.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .background {
                    #if targetEnvironment(macCatalyst)
                    MacCatalystWindowTitle(appState: appState)
                    #endif
                }
                .preferredColorScheme(appearance.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    AADiag.event("scene", ["phase": "\(phase)"])
                    if phase == .background { appState.setAppInBackground(true); AADiag.flush() }
                    else if phase == .active { appState.setAppInBackground(false) }
                }
        }
    }

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceValue) ?? .system
    }
}
