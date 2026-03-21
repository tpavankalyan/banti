import Foundation

actor TestRecorder<Value: Sendable> {
    private var values: [Value] = []

    func append(_ value: Value) {
        values.append(value)
    }

    func snapshot() -> [Value] {
        values
    }
}
