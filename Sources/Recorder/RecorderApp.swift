import SwiftUI

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: RecorderModel

    init() {
        let model = RecorderModel()
        model.launch()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra("Recorder", systemImage: menuBarSymbol) {
            RecorderPanel()
                .environment(model)
                .task { model.onAppear() }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        switch model.state {
        case .idle:      return "mic.fill"
        case .recording: return "record.circle.fill"
        case .paused:    return "pause.circle.fill"
        }
    }
}
