import SwiftUI

struct TranscriptView: View {
    @ObservedObject var viewModel: TranscriptViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1))
            }
            Divider()
            transcriptList
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var headerBar: some View {
        HStack {
            Circle()
                .fill(viewModel.isListening ? Color.red : Color.gray)
                .frame(width: 10, height: 10)
            Text(viewModel.isListening ? "Listening..." : "Stopped")
                .font(.headline)
            Spacer()
            Text("\(viewModel.segments.filter(\.isFinal).count) segments")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.segments) { segment in
                        segmentRow(segment)
                            .id(segment.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.segments.count) { _, _ in
                if let last = viewModel.segments.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func segmentRow(_ segment: TranscriptSegmentEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(segment.speakerLabel)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(colorForSpeaker(segment.speakerLabel))
                .frame(width: 80, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.text)
                    .font(.body)
                    .opacity(segment.isFinal ? 1.0 : 0.5)
                Text(formatTime(segment.startTime))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func colorForSpeaker(_ label: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan]
        let hash = abs(label.hashValue)
        return colors[hash % colors.count]
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
