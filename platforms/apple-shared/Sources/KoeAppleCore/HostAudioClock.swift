import Darwin

public enum HostAudioClock {
    public static func nowNanoseconds() throws -> UInt64 { try nanoseconds(mach_absolute_time()) }

    public static func nanoseconds(_ ticks: UInt64) throws -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS else {
            throw CaptureError("无法读取音频采样时钟。")
        }
        return try nanoseconds(ticks, numerator: timebase.numer, denominator: timebase.denom)
    }

    static func nanoseconds(_ ticks: UInt64, numerator: UInt32, denominator: UInt32) throws -> UInt64 {
        guard numerator > 0, denominator > 0 else { throw CaptureError("音频采样时钟无效。") }
        let product = ticks.multipliedFullWidth(by: UInt64(numerator))
        guard product.high < UInt64(denominator) else { throw CaptureError("音频采样时钟超出范围。") }
        return UInt64(denominator).dividingFullWidth(product).quotient
    }
}
