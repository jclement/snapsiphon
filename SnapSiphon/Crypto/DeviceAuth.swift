import Foundation
import LocalAuthentication

/// Gate for reading secrets back *out* of the app (the age secret key, the
/// restore script). Face ID / Touch ID with device-passcode fallback.
///
/// Note this guards the reveal/export paths only — backups themselves never
/// need the private key (encryption uses the public recipient list), so a
/// running backup never prompts.
enum DeviceAuth {
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode enrolled — there is nothing to authenticate against,
            // and the device is unprotected anyway. Don't brick the feature.
            return true
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: reason)) ?? false
    }
}
