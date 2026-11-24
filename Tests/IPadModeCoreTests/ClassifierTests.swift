import Testing
@testable import IPadModeCore

@Test func classifiesKinds() {
    #expect(DisplayClassifier.classify(vendor: 0x6161706C, product: 0x69506164, isVirtual: true, isAirPlay: true) == .sidecar)
    #expect(DisplayClassifier.classify(vendor: 0x1A1D, product: 1, isVirtual: true, isAirPlay: false) == .ownVirtual)
    #expect(DisplayClassifier.classify(vendor: 0x30AE, product: 0x68F6, isVirtual: false, isAirPlay: false) == .physical)
    #expect(DisplayClassifier.classify(vendor: 0x1234, product: 1, isVirtual: true, isAirPlay: false) == .otherVirtual)
}
