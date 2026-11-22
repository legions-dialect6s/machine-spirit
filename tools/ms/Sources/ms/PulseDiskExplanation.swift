import Darwin
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The model can select the lead observation. All displayed facts come from disk measurements.
struct PulseDiskExplanation {
    struct Input {
        let startupFreeBytes: UInt64?
        let startupReserveBytes: UInt64?
        let startupDeltaBytes: Int64?
        let projectFreeBytes: UInt64?
        let projectThresholdBytes: UInt64?
        let projectDeltaBytes: Int64?
        let previewStatus: String
        let reclaimableBytes: UInt64?
        var previewCategoryCount: Int? = nil

        private func diskFact(_ subject: String, free: UInt64?, threshold: UInt64?, delta: Int64?) -> String? {
            guard let free else { return nil }
            var fact = "\(subject) has \(amount(free)) free"
            if let threshold, free < threshold {
                fact += ", below its \(amount(threshold)) review threshold"
            }
            fact += "."
            if let delta, delta != 0 {
                let direction = delta < 0 ? "fell" : "rose"
                fact += " Its free space \(direction) by \(amount(delta.magnitude)) since the last hourly sample."
            }
            return fact
        }

        private func amount(_ bytes: UInt64) -> String {
            if bytes > 0 && bytes < PulseDiskReview.gibibyte / 20 {
                return "\(bytes) bytes"
            }
            return PulseDiskReview.gib(bytes)
        }

        var facts: [String] {
            let startup = diskFact("The startup disk", free: startupFreeBytes,
                                   threshold: startupReserveBytes, delta: startupDeltaBytes)
            let project = diskFact("The project drive", free: projectFreeBytes,
                                   threshold: projectThresholdBytes, delta: projectDeltaBytes)
            var preview: String
            switch (previewStatus, reclaimableBytes) {
            case ("ok", let bytes?):
                if bytes == 0 {
                    preview = "The project preview estimates zero reclaimable bytes."
                } else {
                    let categories = previewCategoryCount.flatMap { count in
                        count > 0 ? " across \(count) \(count == 1 ? "category" : "categories")" : nil
                    } ?? ""
                    preview = "The project preview estimates \(amount(bytes)) may be reclaimable\(categories)."
                }
                if let free = projectFreeBytes, let threshold = projectThresholdBytes, free < threshold {
                    let shortfall = threshold - free
                    if bytes >= shortfall {
                        preview += " Realizing that estimate would cover the \(amount(shortfall)) needed to reach the project drive’s review threshold."
                    } else {
                        preview += " Even if the full estimate were recovered, the drive would still be \(amount(shortfall - bytes)) below its review threshold."
                    }
                }
            case ("blocked", _):
                preview = "The project preview is blocked, so the reclaimable amount is unknown."
            default:
                preview = "The project preview is unavailable, so the reclaimable amount is unknown."
            }
            return [startup, project, preview].compactMap { $0 }
        }
    }

    let text: String
    let source: String
    let reason: String
    var json: [String: Any] { ["source": source, "reason": reason, "text": text] }

    struct Resources {
        let pressure: Int32?
        let swapUsedBytes: UInt64?

        static func current() -> Self {
            var pressure: Int32 = 0, size = MemoryLayout<Int32>.size
            let pressureOK = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0
            var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
            let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
            return Self(pressure: pressureOK ? pressure : nil, swapUsedBytes: swapOK ? swap.xsu_used : nil)
        }

        func fallbackReason(for input: Input) -> String? {
            switch pressure {
            case 1: break
            case 2, 4: return "elevatedMemoryPressure"
            default: return "memoryPressureUnknown"
            }
            if let free = input.startupFreeBytes, let reserve = input.startupReserveBytes,
               free < reserve, let swapUsedBytes, swapUsedBytes > free {
                return "lowDiskWithHighSwap"
            }
            return nil
        }
    }

    static func explain(_ input: Input, resources: Resources = .current(),
                        chooseLead: ([String]) async throws -> Int? = modelChoice) async -> Self {
        let facts = input.facts
        func summary(lead: Int, source: String, reason: String) -> Self {
            var ordered = facts
            ordered.insert(ordered.remove(at: lead), at: 0)
            return Self(text: ordered.joined(separator: " "), source: source, reason: reason)
        }
        if let reason = resources.fallbackReason(for: input) {
            return summary(lead: 0, source: "deterministic", reason: reason)
        }
        guard facts.count > 1 else {
            return summary(lead: 0, source: "deterministic", reason: "noDiskReading")
        }
        do {
            guard let lead = try await chooseLead(facts) else {
                return summary(lead: 0, source: "deterministic", reason: "modelUnavailable")
            }
            guard facts.indices.contains(lead) else {
                return summary(lead: 0, source: "deterministic", reason: "invalidModelSelection")
            }
            return summary(lead: lead, source: "foundationModels", reason: "modelSelectedLead")
        } catch {
            return summary(lead: 0, source: "deterministic", reason: "modelError")
        }
    }

    private static func modelChoice(_ facts: [String]) async throws -> Int? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else { return nil }
            let ids = facts.indices.map { "fact\($0)" }
            let options = DynamicGenerationSchema(name: "Fact", anyOf: ids)
            let selection = DynamicGenerationSchema(name: "DiskSummary", properties: [
                .init(name: "lead", schema: options)
            ])
            let schema = try GenerationSchema(root: selection, dependencies: [])
            let session = LanguageModelSession(model: model, tools: [], instructions:
                "Choose the fact that best explains current storage pressure. Weigh trends and review thresholds. A preview is an estimate.")
            let prompt = zip(ids, facts).map { "\($0) = \($1)" }.joined(separator: "\n")
            let response = try await session.respond(to: prompt, schema: schema,
                                                     options: .init(sampling: .greedy, maximumResponseTokens: 40))
            let selected = try response.content.value(String.self, forProperty: "lead")
            return ids.firstIndex(of: selected)
        }
        #endif
        return nil
    }
}
