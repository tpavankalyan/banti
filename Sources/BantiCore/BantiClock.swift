// Sources/BantiCore/BantiClock.swift
import Foundation

public enum BantiClock {
    private static let ratio: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Current time in nanoseconds. Monotonic. Safe to call from any thread.
    public static func nowNs() -> UInt64 {
        mach_absolute_time() * ratio.numer / ratio.denom
    }
}
