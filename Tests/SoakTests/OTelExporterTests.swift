// Tests for OTelExporter, verified against a real local HTTP server
// rather than a mocked URLProtocol - this genuinely proves the wire-level
// behavior (a real POST, real JSON, the right endpoint) rather than just
// proving the code calls URLSession's API correctly. Uses Python's
// built-in http.server as the capture server, since it's present on both
// this machine and GitHub's macos-latest CI runners with no extra setup.
import XCTest
import Foundation
@testable import Telemetry

final class OTelExporterTests: XCTestCase {
    private var workDirectory: URL!
    private var captureServer: Process!
    private let port = 18089

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OTelExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        captureServer?.terminate()
        captureServer?.waitUntilExit()
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// Starts a tiny local HTTP server that writes the body of exactly
    /// one POST request to `capturedBodyURL`, then replies 200 OK. Real
    /// bytes over a real socket, not a mocked request handler.
    private func startCaptureServer(capturedBodyURL: URL, statusCode: Int = 200) async throws {
        let script = """
        import http.server, sys
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers['Content-Length'])
                body = self.rfile.read(length)
                with open(sys.argv[2], 'wb') as f:
                    f.write(body)
                self.send_response(int(sys.argv[3]))
                self.end_headers()
            def log_message(self, format, *args):
                pass
        http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
        """
        let scriptURL = workDirectory.appendingPathComponent("capture_server.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path, String(port), capturedBodyURL.path, String(statusCode)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        captureServer = process

        // Give the server a moment to actually bind and start listening.
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    private func sample(jobID: String, residentBytes: UInt64) -> TimestampedMetrics {
        TimestampedMetrics(
            jobID: jobID,
            metrics: TaskMetrics(residentBytes: residentBytes, userTimeSeconds: 1.5, systemTimeSeconds: 0.5)
        )
    }

    /// The core positive case: a real batch, sent over a real POST, is
    /// received by a real server with a well-formed OTLP JSON body
    /// carrying the actual values and job ID we sent.
    func testExportSendsRealOTLPJSONOverHTTP() async throws {
        let capturedBodyURL = workDirectory.appendingPathComponent("captured.json")
        try await startCaptureServer(capturedBodyURL: capturedBodyURL)

        let samples = [sample(jobID: "job-abc", residentBytes: 22_347_776)]
        try await OTelExporter.export(samples, to: "http://127.0.0.1:\(port)/v1/metrics")

        let capturedData = try Data(contentsOf: capturedBodyURL)
        let json = try JSONSerialization.jsonObject(with: capturedData) as? [String: Any]
        let resourceMetrics = try XCTUnwrap((json?["resourceMetrics"] as? [[String: Any]])?.first)
        let scopeMetrics = try XCTUnwrap((resourceMetrics["scopeMetrics"] as? [[String: Any]])?.first)
        let metrics = try XCTUnwrap(scopeMetrics["metrics"] as? [[String: Any]])

        let metricNames = metrics.compactMap { $0["name"] as? String }
        XCTAssertEqual(
            Set(metricNames),
            ["job.memory.resident_bytes", "job.cpu.user_seconds", "job.cpu.system_seconds"]
        )

        let memoryMetric = try XCTUnwrap(metrics.first { $0["name"] as? String == "job.memory.resident_bytes" })
        let gauge = try XCTUnwrap(memoryMetric["gauge"] as? [String: Any])
        let dataPoint = try XCTUnwrap((gauge["dataPoints"] as? [[String: Any]])?.first)
        XCTAssertEqual(dataPoint["asInt"] as? String, "22347776")

        let attributes = try XCTUnwrap(dataPoint["attributes"] as? [[String: Any]])
        let jobIDAttribute = try XCTUnwrap(attributes.first { $0["key"] as? String == "job.id" })
        let jobIDValue = try XCTUnwrap(jobIDAttribute["value"] as? [String: Any])
        XCTAssertEqual(jobIDValue["stringValue"] as? String, "job-abc")
    }

    /// Exporting an empty batch must not send any request at all - there
    /// is nothing meaningful to report, and a request with an empty
    /// metrics list would just be noise for the collector to parse.
    func testExportDoesNothingForEmptyBatch() async throws {
        // No capture server started at all: if export() tried to send
        // anything, this would fail with a connection error, since
        // nothing is listening on this port.
        try await OTelExporter.export([], to: "http://127.0.0.1:\(port)/v1/metrics")
    }

    /// A malformed endpoint URL must fail clearly before any network
    /// activity is attempted.
    func testExportThrowsForInvalidEndpoint() async throws {
        do {
            try await OTelExporter.export([sample(jobID: "job-1", residentBytes: 1024)], to: "")
            XCTFail("expected invalidEndpoint to be thrown")
        } catch let error as OTelExportError {
            guard case .invalidEndpoint = error else {
                XCTFail("expected invalidEndpoint, got \(error)")
                return
            }
        }
    }

    /// A collector that responds with a non-2xx status must be surfaced
    /// as a clear httpError, not silently treated as success.
    func testExportThrowsOnNon2xxResponse() async throws {
        let capturedBodyURL = workDirectory.appendingPathComponent("captured.json")
        try await startCaptureServer(capturedBodyURL: capturedBodyURL, statusCode: 503)

        do {
            try await OTelExporter.export(
                [sample(jobID: "job-1", residentBytes: 1024)],
                to: "http://127.0.0.1:\(port)/v1/metrics"
            )
            XCTFail("expected httpError to be thrown")
        } catch let error as OTelExportError {
            guard case .httpError(let statusCode) = error else {
                XCTFail("expected httpError, got \(error)")
                return
            }
            XCTAssertEqual(statusCode, 503)
        }
    }
}
