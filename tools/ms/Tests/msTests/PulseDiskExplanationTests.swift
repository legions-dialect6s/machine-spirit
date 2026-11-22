import Foundation
import Testing
@testable import ms

private let sample = PulseDiskExplanation.Input(
    startupFreeBytes: 14 << 30, startupReserveBytes: 30 << 30, startupDeltaBytes: nil,
    projectFreeBytes: 60 << 30, projectThresholdBytes: 180 << 30, projectDeltaBytes: -(2 << 30),
    previewStatus: "ok", reclaimableBytes: 4 << 30, previewCategoryCount: 2)

@Test func explanationSkipsInferenceWhenPressureIsElevatedOrUnknown() async {
    for pressure in [Int32(2), 4, 0, nil] {
        let result = await PulseDiskExplanation.explain(sample, resources: .init(pressure: pressure, swapUsedBytes: 0)) { _ in
            Issue.record("Model was called during memory pressure")
            return 0
        }
        #expect(result.source == "deterministic")
        #expect(result.text.contains("4.0 GiB may be reclaimable"))
    }
    let result = await PulseDiskExplanation.explain(sample, resources: .init(pressure: 1, swapUsedBytes: 20 << 30)) { _ in
        Issue.record("Model was called with low disk and high swap")
        return nil
    }
    #expect(result.reason == "lowDiskWithHighSwap")
}

@Test func explanationUsesOnlyMeasuredFactsAndFixedVocabulary() async {
    let resources = PulseDiskExplanation.Resources(pressure: 1, swapUsedBytes: 0)
    let result = await PulseDiskExplanation.explain(sample, resources: resources) { facts in
        #expect(facts.count == 3)
        #expect(facts[1].contains("fell by 2.0 GiB"))
        return 1
    }
    #expect(result.text.hasPrefix("The project drive"))
    #expect(result.source == "foundationModels")
    #expect(result.text.contains("across 2 categories"))
    #expect(result.text.contains("116.0 GiB below its review threshold"))
    let invalid = await PulseDiskExplanation.explain(sample, resources: resources) { _ in 9 }
    #expect(invalid.reason == "invalidModelSelection")
    let unavailable = await PulseDiskExplanation.explain(sample, resources: resources) { _ in nil }
    #expect(unavailable.reason == "modelUnavailable")
    let failed = await PulseDiskExplanation.explain(sample, resources: resources) { _ in throw CancellationError() }
    #expect(failed.reason == "modelError")

    let untrusted = PulseDiskExplanation.Input(
        startupFreeBytes: nil, startupReserveBytes: nil, startupDeltaBytes: nil,
        projectFreeBytes: nil, projectThresholdBytes: nil, projectDeltaBytes: nil,
        previewStatus: "/private/project/secret", reclaimableBytes: 45678)
    #expect(untrusted.facts.count == 1)
    #expect(untrusted.facts.first?.contains("unknown") == true)
    #expect(untrusted.facts.first?.contains("secret") == false)
    #expect(untrusted.facts.first?.contains("45678") == false)
}

@Test func explanationComparesFreshEstimatesWithCurrentShortfall() {
    func facts(status: String, estimate: UInt64?, free: UInt64 = 8 << 30) -> String {
        let input = PulseDiskExplanation.Input(
            startupFreeBytes: nil, startupReserveBytes: nil, startupDeltaBytes: nil,
            projectFreeBytes: free, projectThresholdBytes: 10 << 30, projectDeltaBytes: nil,
            previewStatus: status, reclaimableBytes: estimate)
        return input.facts.joined(separator: " ")
    }
    #expect(facts(status: "ok", estimate: 2 << 30).contains("would cover the 2.0 GiB needed"))
    #expect(facts(status: "ok", estimate: 3 << 30).contains("would cover the 2.0 GiB needed"))
    #expect(facts(status: "ok", estimate: 1 << 30).contains("still be 1.0 GiB below"))
    #expect(!facts(status: "blocked", estimate: nil).contains("would"))
    #expect(!facts(status: "ok", estimate: 3 << 30, free: 10 << 30).contains("would"))
}
