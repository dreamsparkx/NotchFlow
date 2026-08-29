import CoreGraphics
import Darwin

enum DisplayBrightness {
    typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )

    static func get() -> Double? {
        guard let framework, let symbol = dlsym(framework, "DisplayServicesGetBrightness") else { return nil }
        let function = unsafeBitCast(symbol, to: GetFunction.self)
        var value: Float = 0
        return function(CGMainDisplayID(), &value) == 0 ? Double(value) : nil
    }

    static func set(_ value: Double) -> Bool {
        guard let framework, let symbol = dlsym(framework, "DisplayServicesSetBrightness") else { return false }
        let function = unsafeBitCast(symbol, to: SetFunction.self)
        return function(CGMainDisplayID(), Float(value)) == 0
    }
}
