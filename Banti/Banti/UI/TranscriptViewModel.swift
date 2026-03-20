import Foundation
import SwiftUI

@MainActor
final class TranscriptViewModel: ObservableObject {
    @Published var segments: [TranscriptSegmentEvent] = []
    @Published var isListening = false
    private let eventHub: EventHubActor
    private var subscriptionID: SubscriptionID?

    init(eventHub: EventHubActor) {
        self.eventHub = eventHub
    }

    func startListening() async {
        subscriptionID = await eventHub.subscribe(TranscriptSegmentEvent.self) { [weak self] event in
            guard let self else { return }
            await MainActor.run { [self] in
                if event.isFinal {
                    if let last = self.segments.last, !last.isFinal {
                        self.segments.removeLast()
                    }
                    self.segments.append(event)
                } else {
                    if let last = self.segments.last, !last.isFinal {
                        self.segments[self.segments.count - 1] = event
                    } else {
                        self.segments.append(event)
                    }
                }
            }
        }
        isListening = true
    }

    func stopListening() async {
        if let subID = subscriptionID {
            await eventHub.unsubscribe(subID)
            subscriptionID = nil
        }
        isListening = false
    }
}
