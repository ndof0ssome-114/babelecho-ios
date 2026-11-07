import Foundation
import XCTest
@testable import BabelEchoCoreChecks

final class RegressionChecks: XCTestCase {
    func testWAVFinalizationIsIdempotentAndRecoversOnRelease() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let writer = try WAVWriter(url: url)
            try writer.append([-32768, 0, 32767])
        }
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(data.count, 50)
        XCTAssertEqual(Array(data.suffix(6)), [0, 128, 0, 0, 255, 127])
        let writer = try WAVWriter(url: url)
        try writer.close()
        try writer.close()
        XCTAssertThrowsError(try writer.append([1]))
    }
    private func response(_ request: URLRequest, _ object: [String: Any], status: Int = 200) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    private func configured(base: String = "https://api.deepseek.com/v1", noAuth: Bool = false, thinking: String? = "disabled") -> AppSettings {
        var settings = AppSettings()
        var catalog = ProviderCatalog()
        catalog.text = [TextProvider(id: "test", enabled: true, baseURL: base, noAuth: noAuth)]
        catalog.roles["summary"] = ModelRole(provider: "test", model: "chosen-model", thinking: thinking)
        settings.providers = catalog
        return settings
    }
    private let complete: [String: Any] = ["choices": [["message": ["content": "summary"], "finish_reason": "stop"]]]

    func testOlderModelRoleAndUsageDecode() throws {
        let role = try JSONDecoder().decode(ModelRole.self, from: Data(#"{"provider":"test","model":"manual"}"#.utf8))
        XCTAssertNil(role.thinking)
        let usage = try JSONDecoder().decode(TextUsage.self, from: Data(#"{"calls":1,"promptTokens":7,"completionTokens":9,"unreportedCalls":0}"#.utf8))
        XCTAssertNil(usage.reasoningTokens)
        var catalog = ProviderCatalog()
        catalog.roles["summary"]?.thinking = "invalid"
        XCTAssertThrowsError(try catalog.validated())
    }

    func testChangingProviderDoesNotCarryPreviousModelOrThinking() {
        let local = ModelRole.initial(provider: TextProvider(id: "local", enabled: true, baseURL: "https://custom.example/v1"), task: "summary")
        XCTAssertEqual(local.model, "")
        XCTAssertNil(local.thinking)
        let deepseek = ModelRole.initial(provider: TextProvider(id: "ds", enabled: true, baseURL: "https://api.deepseek.com/v1"), task: "translation")
        XCTAssertEqual(deepseek.thinking, "disabled")
        XCTAssertFalse(ModelRole.isDeepSeek("https://api.deepseek.com.evil.example/v1"))
    }

    func testCaptureDuplicateSelectionStartStopAndFinish() {
        var state = CaptureLifecycle()
        XCTAssertTrue(state.selected())
        XCTAssertFalse(state.selected())
        XCTAssertTrue(state.started())
        XCTAssertFalse(state.started())
        XCTAssertTrue(state.requestStop())
        XCTAssertFalse(state.requestStop())
        XCTAssertTrue(state.finish())
        XCTAssertFalse(state.finish())
        XCTAssertFalse(state.started())
    }

    func testCaptureCancelDuringStartupRejectsLateStart() {
        var state = CaptureLifecycle()
        XCTAssertTrue(state.selected())
        XCTAssertTrue(state.requestStop())
        XCTAssertFalse(state.started())
        XCTAssertTrue(state.finish())
        XCTAssertFalse(state.selected())
        var picker = CaptureLifecycle()
        XCTAssertTrue(picker.finish())
        XCTAssertFalse(picker.selected())
    }

    func testScopedCredentialModelAndThinkingReachRequest() async throws {
        let client = CloudClient(settings: configured(), credentials: { $0 == "llm.test" ? "synthetic-key" : "unrelated-key" }, transport: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "chosen-model")
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
            XCTAssertEqual(body["max_tokens"] as? Int, 4096)
            return try self.response(request, self.complete)
        })
        let result = try await client.chat(task: "summary", system: "s", user: "u")
        XCTAssertEqual(result, "summary")
    }

    func testNoAuthOmitsSavedKeyAndCustomEndpointOmitsThinking() async throws {
        let client = CloudClient(settings: configured(base: "https://custom.example/v1", noAuth: true), credentials: { _ in "unused-synthetic-key" }, transport: { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertNil(body["thinking"])
            return try self.response(request, self.complete)
        })
        _ = try await client.chat(task: "summary", system: "s", user: "u")
    }

    func testEnabledThinkingHasLargerBoundedBudget() async throws {
        let client = CloudClient(settings: configured(thinking: "enabled"), credentials: { _ in "synthetic-key" }, transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["max_tokens"] as? Int, 16384)
            return try self.response(request, self.complete)
        })
        _ = try await client.chat(task: "summary", system: "s", user: "u")
    }

    func testEmptyAndTruncatedResponsesKeepReportedUsageAndFailOnce() async throws {
        for truncated in [false, true] {
            var calls = 0
            var reported: ReportedTextUsage?
            var client = CloudClient(settings: configured(), credentials: { _ in "synthetic-key" }, transport: { request in
                calls += 1
                return try self.response(request, ["choices": [["message": ["content": truncated ? "partial" : ""], "finish_reason": truncated ? "length" : "stop"]],
                    "usage": ["prompt_tokens": 10, "completion_tokens": 20, "completion_tokens_details": ["reasoning_tokens": 18]]])
            })
            client.onTextUsage = { _, usage in reported = usage }
            do { _ = try await client.chat(task: "summary", system: "s", user: "u"); XCTFail("Incomplete response must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("usage")) }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(reported?.completionTokens, 20)
            XCTAssertEqual(reported?.reasoningTokens, 18)
        }
    }

    func testModelDiscoverySortedDeduplicatedAndUnauthenticated() async throws {
        let client = CloudClient(settings: AppSettings(), credentials: { _ in "" }, transport: { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return try self.response(request, ["data": [["id": "b"], ["id": "a"], ["id": "b"], ["id": ""]]])
        })
        let models = try await client.discoverModels(baseURL: "https://custom.example/v1", key: "unused", noAuth: true)
        XCTAssertEqual(models, ["a", "b"])
    }

    func testUntrustedHTTPAndEmbeddedSecretsRejectedBeforeTransport() async {
        let client = CloudClient(settings: AppSettings(), credentials: { _ in "" }, transport: { request in
            XCTFail("Unsafe endpoint reached transport")
            return try self.response(request, [:])
        })
        for url in ["http://custom.example/v1", "https://user:password@custom.example/v1", "https://custom.example/v1?key=secret"] {
            do { _ = try await client.discoverModels(baseURL: url, key: "", noAuth: true); XCTFail("Unsafe URL accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS")) }
        }
    }

    func testFailedImportPreservesExistingWAV() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("bad.mp4")
        let target = directory.appendingPathComponent("recording.wav")
        let old = Data("existing-local-audio".utf8)
        try Data("invalid-media".utf8).write(to: source)
        try old.write(to: target)
        do { _ = try await MediaImporter.convertToWAV(source: source, destination: target); XCTFail("Invalid media accepted") }
        catch { XCTAssertEqual(try Data(contentsOf: target), old) }
    }

    // MARK: 2026-11 review fixes

    func testPlainHTTPIsOnlyForLocalNetworks() {
        for host in ["127.0.0.1", "localhost", "10.0.0.8", "192.168.1.20", "172.16.0.9", "nas", "gpu.local", "[::1]", "fd00::5", "fe80::1"] {
            XCTAssertTrue(NetworkPolicy.isLocalNetworkHost(host), host)
        }
        for host in ["api.example.com", "8.8.8.8", "172.32.1.1", "2001:db8::1", "", "999.1.1.1"] {
            XCTAssertFalse(NetworkPolicy.isLocalNetworkHost(host), host)
        }
    }

    func testPublicHTTPRejectedEvenWhenHTTPIsEnabledButLocalHTTPAllowed() async throws {
        var settings = AppSettings()
        settings.allowInsecureHTTP = true
        var reached: [String] = []
        let client = CloudClient(settings: settings, credentials: { _ in "" }, transport: { request in
            reached.append(request.url!.host ?? "")
            return try self.response(request, ["data": [["id": "local-model"]]])
        })
        do { _ = try await client.discoverModels(baseURL: "http://api.example.com/v1", key: "", noAuth: true); XCTFail("public HTTP accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS")) }
        let models = try await client.discoverModels(baseURL: "http://192.168.1.5:11434/v1", key: "", noAuth: true)
        XCTAssertEqual(models, ["local-model"])
        XCTAssertEqual(reached, ["192.168.1.5"])
    }

    func testRetryDelaysFollowRetryAfter() {
        XCTAssertEqual(NetworkPolicy.retryDelay(status: 429, retryAfter: "2", attempt: 0), 2)
        XCTAssertEqual(NetworkPolicy.retryDelay(status: 429, retryAfter: "600", attempt: 0), 30)
        XCTAssertEqual(NetworkPolicy.retryDelay(status: 503, retryAfter: nil, attempt: 1), 2)
        XCTAssertNil(NetworkPolicy.retryDelay(status: 429, retryAfter: "1", attempt: NetworkPolicy.maxAttempts - 1))
        XCTAssertNil(NetworkPolicy.retryDelay(status: 401, retryAfter: nil, attempt: 0))
        XCTAssertEqual(NetworkPolicy.redact("bad key sk-secret-123", authorization: "Bearer sk-secret-123"), "bad key [redacted]")
    }

    func testTransientFailureIsRetriedAndKeysAreRedacted() async throws {
        var calls = 0
        let client = CloudClient(settings: AppSettings(), credentials: { _ in "" }, transport: { request in
            calls += 1
            if calls == 1 { return try self.response(request, ["error": ["message": "busy"]], status: 503) }
            return try self.response(request, ["data": [["id": "m"]]])
        })
        let models = try await client.discoverModels(baseURL: "https://custom.example/v1", key: "sk-visible-key", noAuth: false)
        XCTAssertEqual(models, ["m"])
        XCTAssertEqual(calls, 2)

        calls = 0
        let rejecting = CloudClient(settings: AppSettings(), credentials: { _ in "" }, transport: { request in
            calls += 1
            return try self.response(request, ["error": ["message": "invalid key sk-visible-key"]], status: 401)
        })
        do { _ = try await rejecting.discoverModels(baseURL: "https://custom.example/v1", key: "sk-visible-key", noAuth: false); XCTFail("401 accepted") }
        catch {
            XCTAssertEqual(calls, 1, "401 is not retried")
            XCTAssertFalse(error.localizedDescription.contains("sk-visible-key"))
            XCTAssertTrue(error.localizedDescription.contains("[redacted]"))
        }
    }
}
