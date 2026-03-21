import Foundation

enum EnvKey {
    static let deepgramAPIKey = "DEEPGRAM_API_KEY"
    static let deepgramModel = "DEEPGRAM_MODEL"
    static let deepgramLanguage = "DEEPGRAM_LANGUAGE"
    static let cerebrasAPIKey = "CEREBRAS_API_KEY"
    static let cerebrasModel = "CEREBRAS_MODEL"
    static let anthropicAPIKey = "ANTHROPIC_API_KEY"
    static let anthropicModel = "ANTHROPIC_MODEL"
    static let llmProvider = "LLM_PROVIDER"        // "claude" | "cerebras"
    static let cartesiaAPIKey = "CARTESIA_API_KEY"
    static let cartesiaVoiceID = "CARTESIA_VOICE_ID"
    static let cartesiaModel = "CARTESIA_MODEL"
    static let cameraCaptureIntervalMs   = "CAMERA_CAPTURE_INTERVAL_MS"
    static let visionProvider            = "VISION_PROVIDER"
    static let sceneDescriptionIntervalS = "SCENE_DESCRIPTION_INTERVAL_S"
    static let sceneDescriptionPrompt    = "SCENE_DESCRIPTION_PROMPT"
    static let anthropicVisionModel      = "ANTHROPIC_VISION_MODEL"
}
