import Testing
import AppKit
import CoreTransferable
import Darwin
import UniformTypeIdentifiers
@testable import Ghostty

struct TransferablePasteboardTests {
    // MARK: - Test Helpers

    /// A simple Transferable type for testing pasteboard conversion.
    private struct DummyTransferable: Transferable, Equatable {
        let payload: String

        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(contentType: .utf8PlainText) { value in
                value.payload.data(using: .utf8)!
            } importing: { data in
                let string = String(data: data, encoding: .utf8)!
                return DummyTransferable(payload: string)
            }
        }
    }

    /// A Transferable type that registers multiple content types.
    private struct MultiTypeTransferable: Transferable {
        let text: String

        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(contentType: .utf8PlainText) { value in
                value.text.data(using: .utf8)!
            } importing: { data in
                MultiTypeTransferable(text: String(data: data, encoding: .utf8)!)
            }
            DataRepresentation(contentType: .plainText) { value in
                value.text.data(using: .utf8)!
            } importing: { data in
                MultiTypeTransferable(text: String(data: data, encoding: .utf8)!)
            }
        }
    }

    /// A Transferable whose export must re-enter the main actor. This mirrors
    /// teardown-time promised pasteboard resolution, where AppKit can ask for
    /// bytes while the main thread is the provider caller.
    private struct MainActorExportTransferable: Transferable {
        let payload: String

        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(contentType: .utf8PlainText) { value async throws -> Data in
                await MainActor.run {
                    Data(value.payload.utf8)
                }
            } importing: { data in
                MainActorExportTransferable(payload: String(decoding: data, as: UTF8.self))
            }
        }
    }

    // MARK: - Basic Functionality

    @Test func pasteboardItemIsCreated() {
        let transferable = DummyTransferable(payload: "hello")
        let item = transferable.pasteboardItem()
        #expect(item != nil)
    }

    @Test func pasteboardItemContainsExpectedType() {
        let transferable = DummyTransferable(payload: "hello")
        guard let item = transferable.pasteboardItem() else {
            Issue.record("Expected pasteboard item to be created")
            return
        }

        let expectedType = NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)
        #expect(item.types.contains(expectedType))
    }

    @Test func pasteboardItemProvidesCorrectData() {
        let transferable = DummyTransferable(payload: "test data")
        guard let item = transferable.pasteboardItem() else {
            Issue.record("Expected pasteboard item to be created")
            return
        }

        let pasteboardType = NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)

        // Write to a pasteboard to trigger data provider
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        // Read back the data
        guard let data = pasteboard.data(forType: pasteboardType) else {
            Issue.record("Expected data to be available on pasteboard")
            return
        }

        let string = String(data: data, encoding: .utf8)
        #expect(string == "test data")
    }

    @MainActor
    @Test func pasteboardItemResolvesMainActorExportFromMainThread() throws {
        let pid = fork()
        if pid == 0 {
            let status = Self.runMainThreadResolutionProbe()
            _exit(status)
        }

        #expect(pid > 0)
        guard pid > 0 else { return }

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(3)
        while waitpid(pid, &status, WNOHANG) == 0 {
            guard Date() < deadline else {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                Issue.record("Timed out resolving Transferable pasteboard data on the main thread")
                return
            }
            usleep(10_000)
        }

        #expect(Self.waitStatusExitCode(status) == 0)
    }

    @MainActor
    private static func runMainThreadResolutionProbe() -> Int32 {
        guard Thread.isMainThread else { return 70 }

        let transferable = MainActorExportTransferable(payload: "main-thread-data")
        guard let item = transferable.pasteboardItem() else { return 71 }

        let pasteboardType = NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)
        guard let data = item.data(forType: pasteboardType) else { return 72 }
        guard String(decoding: data, as: UTF8.self) == "main-thread-data" else { return 73 }
        return 0
    }

    private static func waitStatusExitCode(_ status: Int32) -> Int32? {
        guard status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }

    // MARK: - Multiple Content Types

    @Test func multipleTypesAreRegistered() {
        let transferable = MultiTypeTransferable(text: "multi")
        guard let item = transferable.pasteboardItem() else {
            Issue.record("Expected pasteboard item to be created")
            return
        }

        let utf8Type = NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)
        let plainType = NSPasteboard.PasteboardType(UTType.plainText.identifier)

        #expect(item.types.contains(utf8Type))
        #expect(item.types.contains(plainType))
    }

    @Test func multipleTypesProvideCorrectData() {
        let transferable = MultiTypeTransferable(text: "shared content")
        guard let item = transferable.pasteboardItem() else {
            Issue.record("Expected pasteboard item to be created")
            return
        }

        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        // Both types should provide the same content
        let utf8Type = NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)
        let plainType = NSPasteboard.PasteboardType(UTType.plainText.identifier)

        if let utf8Data = pasteboard.data(forType: utf8Type) {
            #expect(String(data: utf8Data, encoding: .utf8) == "shared content")
        }

        if let plainData = pasteboard.data(forType: plainType) {
            #expect(String(data: plainData, encoding: .utf8) == "shared content")
        }
    }
}
