import Foundation

enum EnvKey {
    static let deepgramAPIKey = "DEEPGRAM_API_KEY"
    static let deepgramModel = "DEEPGRAM_MODEL"
    static let deepgramLanguage = "DEEPGRAM_LANGUAGE"
    static let anthropicAPIKey = "ANTHROPIC_API_KEY"
    static let cameraCaptureIntervalMs   = "CAMERA_CAPTURE_INTERVAL_MS"
    static let visionProvider            = "VISION_PROVIDER"
    static let sceneDescriptionIntervalS = "SCENE_DESCRIPTION_INTERVAL_S"
    static let sceneDescriptionPrompt    = "SCENE_DESCRIPTION_PROMPT"
    static let anthropicVisionModel      = "ANTHROPIC_VISION_MODEL"
    static let screenCaptureIntervalMs   = "SCREEN_CAPTURE_INTERVAL_MS"
    static let screenDescriptionIntervalS = "SCREEN_DESCRIPTION_INTERVAL_S"
    static let screenDescriptionPrompt   = "SCREEN_DESCRIPTION_PROMPT"
    static let axDebounceMs              = "AX_DEBOUNCE_MS"
    static let axSelectedTextMaxChars    = "AX_SELECTED_TEXT_MAX_CHARS"
    static let cartesiaAPIKey            = "CARTESIA_API_KEY"
    static let cartesiaVoiceID           = "CARTESIA_VOICE_ID"
}
