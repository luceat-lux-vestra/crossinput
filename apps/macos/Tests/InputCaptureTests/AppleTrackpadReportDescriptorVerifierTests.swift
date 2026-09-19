import Foundation
import Testing
@testable import InputCapture

@Suite("Apple trackpad report descriptor verifier")
struct AppleTrackpadReportDescriptorVerifierTests {
    @Test("accepts the proven 78-byte report layout")
    func acceptsSupportedDescriptor() throws {
        let descriptor = AppleTrackpadReportDescriptorVerifier.supportedDescriptor
        #expect(descriptor.count == 78)
        try AppleTrackpadReportDescriptorVerifier.verify(descriptor)
    }

    @Test("rejects any one-byte layout mutation")
    func rejectsMutation() {
        var descriptor = AppleTrackpadReportDescriptorVerifier.supportedDescriptor
        descriptor[22] = 0x03
        #expect(
            throws: AppleTrackpadReportDescriptorVerifier.VerificationError
                .unsupportedDescriptor
        ) {
            try AppleTrackpadReportDescriptorVerifier.verify(descriptor)
        }
    }

    @Test("rejects truncated descriptor")
    func rejectsTruncation() {
        let descriptor = AppleTrackpadReportDescriptorVerifier.supportedDescriptor.dropLast()
        #expect(
            throws: AppleTrackpadReportDescriptorVerifier.VerificationError
                .unsupportedDescriptor
        ) {
            try AppleTrackpadReportDescriptorVerifier.verify(Data(descriptor))
        }
    }
}
