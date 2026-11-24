import Foundation
import CPrivateDisplay

public enum PrivateAPI {
    /// Which private APIs resolved at runtime. All false when IPADMODE_SIMULATE_MISSING_API=1.
    public static var status: IPMPrivateAPIStatus {
        if ProcessInfo.processInfo.environment["IPADMODE_SIMULATE_MISSING_API"] == "1" {
            return IPMPrivateAPIStatus(virtualDisplay: false, configureEnabled: false, displayList: false, displayInfo: false)
        }
        return IPMGetPrivateAPIStatus()
    }

    public static var allAvailable: Bool {
        let s = status
        return s.virtualDisplay && s.configureEnabled && s.displayList && s.displayInfo
    }
}
