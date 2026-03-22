// Banti/Banti/UI/EventLogView.swift
import SwiftUI

struct EventLogView: View {
    @ObservedObject var viewModel: EventLogViewModel

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
            feedList
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var headerBar: some View {
        HStack {
            Circle()
                .fill(viewModel.isListening ? Color.red : Color.gray)
                .frame(width: 10, height: 10)
            Text(viewModel.isListening ? "Listening…" : "Stopped")
                .font(.headline)
            Spacer()
            Text("\(viewModel.entries.count) events")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var feedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.entries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.entries.last?.id) { _, id in
                if let id {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: EventLogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.tag)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(color(for: entry.tag))
                .frame(width: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.body)
                Text(entry.timestampFormatted)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func color(for tag: String) -> Color {
        switch tag {
        case "[AUDIO]":   return .secondary
        case "[CAMERA]":  return .blue
        case "[RAW]":     return .orange
        case "[SEGMENT]": return .green
        case "[SCENE]":   return .purple
        case "[MODULE]":  return .cyan
        case "[SCREEN]":  return .indigo
        case "[SCRFRM]":  return .teal
        case "[APP]":     return .mint
        case "[AX]":      return .pink
        default:          return .primary
        }
    }
}
