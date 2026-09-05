import Foundation

enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let speakerName        = "localSpeakerName"
        static let silenceTimeout     = "silenceTimeoutSeconds"
        static let silenceThresholdDB = "silenceThresholdDB"
        static let silenceAutoStop    = "silenceAutoStopEnabled"
        static let autoProcess        = "autoProcessAfterSave"
        static let pipelineDir        = "pipelineDirectory"
        static let contexts           = "pipelineContexts"
        static let lastContext        = "lastUsedContext"
    }

    static var speakerName: String {
        get { defaults.string(forKey: Key.speakerName) ?? "" }
        set { defaults.set(newValue, forKey: Key.speakerName) }
    }

    static var silenceTimeout: TimeInterval {
        get { defaults.object(forKey: Key.silenceTimeout) == nil ? 300 : defaults.double(forKey: Key.silenceTimeout) }
        set { defaults.set(newValue, forKey: Key.silenceTimeout) }
    }

    static var silenceThresholdDB: Float {
        get { defaults.object(forKey: Key.silenceThresholdDB) == nil ? -50 : defaults.float(forKey: Key.silenceThresholdDB) }
        set { defaults.set(newValue, forKey: Key.silenceThresholdDB) }
    }

    static var silenceAutoStop: Bool {
        get { defaults.object(forKey: Key.silenceAutoStop) == nil ? true : defaults.bool(forKey: Key.silenceAutoStop) }
        set { defaults.set(newValue, forKey: Key.silenceAutoStop) }
    }

    static var autoProcess: Bool {
        get { defaults.bool(forKey: Key.autoProcess) }
        set { defaults.set(newValue, forKey: Key.autoProcess) }
    }

    static var pipelineDir: String {
        get {
            defaults.string(forKey: Key.pipelineDir)
                ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents/home/transcribe")
        }
        set { defaults.set(newValue, forKey: Key.pipelineDir) }
    }

    static var contexts: [String] {
        get { defaults.stringArray(forKey: Key.contexts) ?? [] }
        set { defaults.set(newValue, forKey: Key.contexts) }
    }

    static var lastContext: String {
        get { defaults.string(forKey: Key.lastContext) ?? "" }
        set { defaults.set(newValue, forKey: Key.lastContext) }
    }
}
