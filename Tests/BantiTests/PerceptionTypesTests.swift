// Tests/BantiTests/PerceptionTypesTests.swift
import XCTest
@testable import BantiCore

final class PerceptionTypesTests: XCTestCase {

    func testStateStructsAreInitializable() {
        let now = Date()
        let face = FaceState(boundingBox: .zero, landmarksDetected: true, updatedAt: now)
        XCTAssertTrue(face.landmarksDetected)

        let emotion = EmotionState(emotions: [("focused", 0.9)], updatedAt: now)
        XCTAssertEqual(emotion.emotions.first?.label, "focused")

        let pose = PoseState(bodyPoints: [:], handPoints: nil, updatedAt: now)
        XCTAssertNil(pose.handPoints)

        let gesture = GestureState(description: "arms crossed", updatedAt: now)
        XCTAssertEqual(gesture.description, "arms crossed")

        let screen = ScreenState(ocrLines: ["hello"], interpretation: "code editor", updatedAt: now)
        XCTAssertEqual(screen.ocrLines.count, 1)

        let activity = ActivityState(description: "typing", updatedAt: now)
        XCTAssertEqual(activity.description, "typing")
    }

    func testPerceptionObservationEnum() {
        let now = Date()
        let obs = PerceptionObservation.emotion(EmotionState(emotions: [], updatedAt: now))
        if case .emotion(let s) = obs {
            XCTAssertTrue(s.emotions.isEmpty)
        } else {
            XCTFail("wrong case")
        }
    }
}
