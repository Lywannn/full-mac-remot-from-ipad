public enum DisplayClassifier {
    /// Vendor ID of our own virtual display.
    public static let ownVendor: UInt32 = 0x1A1D

    /// Apple vendor ("aapl") and iPad product ("iPad") reported by Sidecar.
    private static let appleVendor: UInt32 = 0x6161706C
    private static let iPadProduct: UInt32 = 0x69506164

    /// `product` is the display model number (`DisplayInfo.model`).
    public static func classify(vendor: UInt32, product: UInt32, isVirtual: Bool, isAirPlay: Bool) -> DisplayKind {
        if isAirPlay || (vendor == appleVendor && product == iPadProduct) { return .sidecar }
        if isVirtual { return vendor == ownVendor ? .ownVirtual : .otherVirtual }
        return .physical
    }
}
