// Batches queued metric samples into an OTLP (OpenTelemetry Protocol)
// metrics payload and POSTs it to a local collector over HTTP+JSON.
//
// Ships on port 4318 (OTLP/HTTP), not the port 4317 (OTLP/gRPC) the
// original --stream-otel example implied. gRPC from Swift needs the
// grpc-swift dependency, a meaningfully bigger addition than this
// project's Stage 4 scope calls for - HTTP+JSON is a fully valid,
// spec-supported alternative that needs nothing beyond Foundation's
// own URLSession.
import Foundation

public enum OTelExportError: Error, CustomStringConvertible {
    case invalidEndpoint(String)
    case httpError(statusCode: Int)
    case transportError(String)

    public var description: String {
        switch self {
        case .invalidEndpoint(let endpoint):
            return "invalid OTLP endpoint URL: \(endpoint)"
        case .httpError(let statusCode):
            return "collector responded with HTTP \(statusCode)"
        case .transportError(let message):
            return "network transport error: \(message)"
        }
    }
}

public enum OTelExporter {
    /// Sends every given sample to `endpoint` (e.g.
    /// "http://localhost:4318/v1/metrics") as one OTLP/HTTP+JSON metrics
    /// export request. Does nothing and returns immediately if `samples`
    /// is empty, rather than sending a pointless empty request. Throws
    /// if the endpoint URL is malformed, the network request itself
    /// fails, or the collector responds with a non-2xx status.
    public static func export(_ samples: [TimestampedMetrics], to endpoint: String) async throws {
        guard !samples.isEmpty else { return }
        guard let url = URL(string: endpoint) else {
            throw OTelExportError.invalidEndpoint(endpoint)
        }

        let payload = buildPayload(from: samples)
        let bodyData = try JSONEncoder().encode(payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OTelExportError.transportError("\(error)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OTelExportError.transportError("response was not an HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OTelExportError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    /// Converts a batch of samples into one OTLP ExportMetricsServiceRequest,
    /// with three separate metrics (resident memory, user CPU time, system
    /// CPU time), each carrying one data point per sample, tagged with
    /// that sample's job ID as an attribute so a collector receiving data
    /// for many jobs in one batch can tell them apart.
    static func buildPayload(from samples: [TimestampedMetrics]) -> OTLPExportRequest {
        let memoryPoints = samples.map { sample in
            OTLPNumberDataPoint(
                timeUnixNano: nanoseconds(since: sample.timestamp),
                attributes: [jobIDAttribute(sample.jobID)],
                asDouble: nil,
                asInt: String(sample.metrics.residentBytes)
            )
        }
        let userCPUPoints = samples.map { sample in
            OTLPNumberDataPoint(
                timeUnixNano: nanoseconds(since: sample.timestamp),
                attributes: [jobIDAttribute(sample.jobID)],
                asDouble: sample.metrics.userTimeSeconds,
                asInt: nil
            )
        }
        let systemCPUPoints = samples.map { sample in
            OTLPNumberDataPoint(
                timeUnixNano: nanoseconds(since: sample.timestamp),
                attributes: [jobIDAttribute(sample.jobID)],
                asDouble: sample.metrics.systemTimeSeconds,
                asInt: nil
            )
        }

        let metrics = [
            OTLPMetric(name: "job.memory.resident_bytes", unit: "By", gauge: OTLPGauge(dataPoints: memoryPoints)),
            OTLPMetric(name: "job.cpu.user_seconds", unit: "s", gauge: OTLPGauge(dataPoints: userCPUPoints)),
            OTLPMetric(name: "job.cpu.system_seconds", unit: "s", gauge: OTLPGauge(dataPoints: systemCPUPoints))
        ]

        let scopeMetrics = OTLPScopeMetrics(
            scope: OTLPInstrumentationScope(name: "com.aditeya.darwin-runtime"),
            metrics: metrics
        )
        let resourceMetrics = OTLPResourceMetrics(
            resource: OTLPResource(attributes: [
                OTLPKeyValue(key: "service.name", value: OTLPAnyValue(stringValue: "darwin-server-runtime"))
            ]),
            scopeMetrics: [scopeMetrics]
        )

        return OTLPExportRequest(resourceMetrics: [resourceMetrics])
    }

    private static func jobIDAttribute(_ jobID: String) -> OTLPKeyValue {
        OTLPKeyValue(key: "job.id", value: OTLPAnyValue(stringValue: jobID))
    }

    /// OTLP encodes 64-bit time and integer fields as JSON strings rather
    /// than JSON numbers, to avoid precision loss - JSON numbers are
    /// commonly parsed as IEEE 754 doubles, which cannot represent every
    /// 64-bit integer exactly. timeUnixNano follows that same convention.
    private static func nanoseconds(since date: Date) -> String {
        let nanos = date.timeIntervalSince1970 * 1_000_000_000
        return String(Int64(nanos))
    }
}

// MARK: - OTLP JSON model
//
// A minimal but real subset of the OTLP metrics JSON schema, just enough
// to carry this project's three gauge metrics. Field names and nesting
// match the official OTLP protobuf-to-JSON mapping (resourceMetrics ->
// scopeMetrics -> metrics -> gauge -> dataPoints).

struct OTLPExportRequest: Codable {
    let resourceMetrics: [OTLPResourceMetrics]
}

struct OTLPResourceMetrics: Codable {
    let resource: OTLPResource
    let scopeMetrics: [OTLPScopeMetrics]
}

struct OTLPResource: Codable {
    let attributes: [OTLPKeyValue]
}

struct OTLPScopeMetrics: Codable {
    let scope: OTLPInstrumentationScope
    let metrics: [OTLPMetric]
}

struct OTLPInstrumentationScope: Codable {
    let name: String
}

struct OTLPMetric: Codable {
    let name: String
    let unit: String
    let gauge: OTLPGauge
}

struct OTLPGauge: Codable {
    let dataPoints: [OTLPNumberDataPoint]
}

/// asDouble and asInt are both optional and mutually exclusive - Swift's
/// synthesized Codable conformance omits nil Optional fields from the
/// encoded JSON automatically, so only whichever one is non-nil actually
/// appears in the output, matching OTLP's "oneof" value encoding.
struct OTLPNumberDataPoint: Codable {
    let timeUnixNano: String
    let attributes: [OTLPKeyValue]
    let asDouble: Double?
    let asInt: String?
}

struct OTLPKeyValue: Codable {
    let key: String
    let value: OTLPAnyValue
}

struct OTLPAnyValue: Codable {
    let stringValue: String?
}
