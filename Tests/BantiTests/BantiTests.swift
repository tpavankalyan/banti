import XCTest
@testable import BantiCore

final class BantiTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}

// Compile-time check: audio types exist
private func _audioTypesExist() {
    let _: SpeechState = SpeechState(transcript: "", speakerID: nil, isFinal: false, confidence: 0, updatedAt: Date())
    let _: VoiceEmotionState = VoiceEmotionState(emotions: [], updatedAt: Date())
    let _: SoundState = SoundState(label: "", confidence: 0, updatedAt: Date())
}
