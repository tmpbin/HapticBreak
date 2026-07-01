import Foundation

/// Lightweight Swift wrapper around the private `MultitouchSupport.framework` actuator API.
///
/// Loaded dynamically at runtime via `dlopen` / `dlsym` to avoid bus errors (SIGBUS) from direct
/// `extern` calls on arm64e (Apple Silicon) due to pointer authentication (PAC).
/// Verified working on Apple M5 Pro / macOS 26.5.
final class MultitouchSupport {

    typealias CreateFromDeviceID = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    typealias ActuatorOpen       = @convention(c) (CFTypeRef, UInt32) -> Int32
    typealias ActuatorClose      = @convention(c) (CFTypeRef) -> Int32
    /// `MTActuatorActuate(actuatorRef, actuationID, strengthFlags, scale, timeScale)`.
    /// Real semantics verified by disassembly (macOS 26.5 / `MultitouchSupport`):
    /// - 3rd arg `strengthFlags`: strength **level selection** — `0x1`=Light, `0x2`=Medium, `0x4`=Firm
    ///   (Apple has tuned the curves per model via `ActuatorRevision`; `0`=no level, driven directly by `scale`).
    /// - 4th arg `scale`(float0): **main scale** — pass `1.0` with a level to get the official curve; at 0 the base
    ///   amplitude falls back to the curve default and the timbre is muted.
    /// - 5th arg `timeScale`(float1): scales only the base pulse width (firmware clamps to 4…8ms), not amplitude.
    /// The last two args are **Float32**, passed via **V registers** on arm64; declaring them as integers would
    /// route them to integer registers and read stale values.
    /// Full curve/parameter semantics: see `PrivateHapticEngine.actuateRaw(actuationID:strengthFlags:scale:timeScale:)`.
    typealias ActuatorActuate    = @convention(c) (CFTypeRef, Int32, UInt32, Float32, Float32) -> Int32
    typealias DeviceCreateList   = @convention(c) () -> Unmanaged<CFArray>?

    private let handle: UnsafeMutableRawPointer
    let createFromDeviceID: CreateFromDeviceID
    let actuatorOpen: ActuatorOpen
    let actuatorClose: ActuatorClose
    let actuatorActuate: ActuatorActuate
    let deviceCreateList: DeviceCreateList?

    static let shared = MultitouchSupport()

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private init?() {
        guard let h = dlopen(Self.frameworkPath, RTLD_LAZY) else { return nil }

        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }

        guard
            let create  = sym("MTActuatorCreateFromDeviceID", as: CreateFromDeviceID.self),
            let open    = sym("MTActuatorOpen",  as: ActuatorOpen.self),
            let close   = sym("MTActuatorClose", as: ActuatorClose.self),
            let actuate = sym("MTActuatorActuate", as: ActuatorActuate.self)
        else {
            dlclose(h)
            return nil
        }

        self.handle = h
        self.createFromDeviceID = create
        self.actuatorOpen = open
        self.actuatorClose = close
        self.actuatorActuate = actuate
        self.deviceCreateList = sym("MTDeviceCreateList", as: DeviceCreateList.self)
    }
}
