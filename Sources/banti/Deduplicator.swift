// Sources/banti/Deduplicator.swift
import Foundation
import CoreVideo
import Accelerate

struct Deduplicator {
    private var lastHashes: [String: UInt64] = [:]
    private let threshold = 0  // Hamming distance ≤ 0 → duplicate (exact match only)

    // Returns true if the frame should be processed (is meaningfully new)
    mutating func isNew(pixels: [UInt8], width: Int, height: Int, source: String) -> Bool {
        let hash = Deduplicator.dHash(pixels: pixels, width: width, height: height)
        if let last = lastHashes[source], Deduplicator.hammingDistance(hash, last) <= threshold {
            return false
        }
        lastHashes[source] = hash
        return true
    }

    // Convenience entry point for CVPixelBuffer — downscales to 9x8 grayscale first
    mutating func isNew(pixelBuffer: CVPixelBuffer, source: String) -> Bool {
        guard let pixels = Deduplicator.toGrayscale9x8(pixelBuffer) else { return true }
        return isNew(pixels: pixels, width: 9, height: 8, source: source)
    }

    // dHash: compare adjacent horizontal pixel pairs, 8 comparisons × 8 rows = 64 bits
    static func dHash(pixels: [UInt8], width: Int, height: Int) -> UInt64 {
        precondition(width == 9 && height == 8, "dHash requires 9x8 input")
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let left = pixels[row * 9 + col]
                let right = pixels[row * 9 + col + 1]
                if left != right {
                    hash |= (1 << UInt64(row * 8 + col))
                }
            }
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    // Downscale CVPixelBuffer to 9x8 grayscale using vImage
    static func toGrayscale9x8(_ buffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let srcWidth = CVPixelBufferGetWidth(buffer)
        let srcHeight = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)

        // Convert BGRA/RGBA to grayscale using luma coefficients
        var gray = [UInt8](repeating: 0, count: srcWidth * srcHeight)
        let srcData = base.assumingMemoryBound(to: UInt8.self)

        if pixelFormat == kCVPixelFormatType_32BGRA {
            for i in 0..<(srcWidth * srcHeight) {
                let row = i / srcWidth
                let col = i % srcWidth
                let offset = row * bytesPerRow + col * 4
                let b = Float(srcData[offset])
                let g = Float(srcData[offset + 1])
                let r = Float(srcData[offset + 2])
                gray[i] = UInt8(0.299 * r + 0.587 * g + 0.114 * b)
            }
        } else {
            // Fallback: treat first channel as luma
            for i in 0..<(srcWidth * srcHeight) {
                let row = i / srcWidth
                let col = i % srcWidth
                gray[i] = srcData[row * bytesPerRow + col * 4]
            }
        }

        // Downscale to 9x8 using nearest-neighbour
        var result = [UInt8](repeating: 0, count: 9 * 8)
        for row in 0..<8 {
            for col in 0..<9 {
                let srcRow = row * srcHeight / 8
                let srcCol = col * srcWidth / 9
                result[row * 9 + col] = gray[srcRow * srcWidth + srcCol]
            }
        }
        return result
    }
}
