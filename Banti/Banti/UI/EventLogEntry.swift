// Banti/Banti/UI/EventLogEntry.swift
import Foundation

struct EventLogEntry: Identifiable {
    let id: UUID
    let tag: String
    let text: String
    let timestampFormatted: String
}
