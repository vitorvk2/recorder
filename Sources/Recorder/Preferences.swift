import Foundation

/// Typed wrapper over `UserDefaults` for the app's persisted preferences.
///
/// Keys + sensible defaults live here in one place; `RecorderModel` mirrors these
/// into `@Observable` properties (loading them at launch, writing them back on
/// change) so the UI can bind to them while disk persistence stays out of band.
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

    /// Your name — passed to the pipeline so the summary can label the local
    /// voice (the microphone / right channel) when guessing who said what.
    /// Empty means "don't name the local speaker".
    static var speakerName: String {
        get { defaults.string(forKey: Key.speakerName) ?? "" }
        set { defaults.set(newValue, forKey: Key.speakerName) }
    }

    /// Seconds of two-channel silence before a recording auto-stops. Default 300 (5 min).
    static var silenceTimeout: TimeInterval {
        get { defaults.object(forKey: Key.silenceTimeout) == nil ? 300 : defaults.double(forKey: Key.silenceTimeout) }
        set { defaults.set(newValue, forKey: Key.silenceTimeout) }
    }

    /// dBFS below which a channel counts as silent. Default -50.
    static var silenceThresholdDB: Float {
        get { defaults.object(forKey: Key.silenceThresholdDB) == nil ? -50 : defaults.float(forKey: Key.silenceThresholdDB) }
        set { defaults.set(newValue, forKey: Key.silenceThresholdDB) }
    }

    /// Whether silence auto-stop is active at all. Default true.
    static var silenceAutoStop: Bool {
        get { defaults.object(forKey: Key.silenceAutoStop) == nil ? true : defaults.bool(forKey: Key.silenceAutoStop) }
        set { defaults.set(newValue, forKey: Key.silenceAutoStop) }
    }

    /// Whether to run the pipeline automatically once a recording is saved.
    ///
    /// Defaults to **false**, unlike the Gemini flow this replaced: the pipeline
    /// publishes to Notion, so firing it unattended on every recording is a
    /// bigger side effect than writing a local transcript file.
    static var autoProcess: Bool {
        get { defaults.bool(forKey: Key.autoProcess) }
        set { defaults.set(newValue, forKey: Key.autoProcess) }
    }

    /// Directory of the `transcribe` repo (where docker-compose.yml lives).
    static var pipelineDir: String {
        get {
            defaults.string(forKey: Key.pipelineDir)
                ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents/home/transcribe")
        }
        set { defaults.set(newValue, forKey: Key.pipelineDir) }
    }

    /// Contexts offered in the picker. Empty means "discover from the media root".
    static var contexts: [String] {
        get { defaults.stringArray(forKey: Key.contexts) ?? [] }
        set { defaults.set(newValue, forKey: Key.contexts) }
    }

    /// Context used on the previous recording, pre-selected next time.
    static var lastContext: String {
        get { defaults.string(forKey: Key.lastContext) ?? "" }
        set { defaults.set(newValue, forKey: Key.lastContext) }
    }
}
