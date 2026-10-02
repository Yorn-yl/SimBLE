import Foundation

// The contract between SimBLE and decoder plugins. Built with library evolution, so plugins
// built against an older copy keep loading after additive changes here.
//
// A plugin is a dylib that links this library and exports one entry point:
//
//     @_cdecl("simble_make_decoder_plugin")
//     public func makeDecoderPlugin() -> UnsafeMutableRawPointer {
//         exportDecoderPlugin(MyPlugin())
//     }

public enum PacketDirection: Sendable {
    case toDevice
    case fromDevice
}

/// Where a chunk of bytes travelled. UUIDs are uppercase strings as CoreBluetooth prints them
/// (full 128-bit form for custom UUIDs, 4 hex digits for SIG ones).
public struct PacketContext: Sendable, Hashable {
    public let service: String
    public let characteristic: String
    public let direction: PacketDirection

    public init(service: String, characteristic: String, direction: PacketDirection) {
        self.service = service
        self.characteristic = characteristic
        self.direction = direction
    }
}

/// A table column a plugin fills. `id` must stay stable: the user's column layout is stored by it.
public struct DecoderColumn: Sendable, Hashable {
    public let id: String
    public let title: String
    public let isVisibleByDefault: Bool

    public init(id: String, title: String, isVisibleByDefault: Bool = true) {
        self.id = id
        self.title = title
        self.isVisibleByDefault = isVisibleByDefault
    }
}

public struct DecodedField: Sendable, Hashable, Codable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// One protocol message completed by a chunk.
public struct DecodedMessage: Sendable, Hashable, Codable {
    /// Short values keyed by `DecoderColumn.id`.
    public var columns: [String: String]
    /// Ordered name/value lines for the inspector; values may span lines.
    public var fields: [DecodedField]
    /// Marks the message as a failure, e.g. an error status, so the table highlights it.
    public var isError: Bool

    public init(columns: [String: String] = [:], fields: [DecodedField] = [], isError: Bool = false) {
        self.columns = columns
        self.fields = fields
        self.isError = isError
    }
}

/// Decodes one byte stream (one peripheral, characteristic and direction). Instances keep state,
/// such as a partial frame, between calls and are only called from one queue at a time.
public protocol PacketDecoder: AnyObject {
    /// Messages this chunk completes; empty while a message is still arriving.
    func decode(_ data: Data) -> [DecodedMessage]
}

public protocol DecoderPlugin: AnyObject {
    /// Shown in the UI and used to key its columns; keep it stable.
    var name: String { get }
    var columns: [DecoderColumn] { get }
    /// Whether this plugin decodes the stream; the first loaded plugin that accepts it wins.
    func accepts(_ context: PacketContext) -> Bool
    func makeDecoder(for context: PacketContext) -> PacketDecoder
}

/// Hands a plugin to SimBLE from the `simble_make_decoder_plugin` entry point.
public func exportDecoderPlugin(_ plugin: DecoderPlugin) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(plugin as AnyObject).toOpaque()
}

/// Takes ownership of what `exportDecoderPlugin` returned.
public func importDecoderPlugin(_ pointer: UnsafeMutableRawPointer) -> DecoderPlugin? {
    Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as? DecoderPlugin
}

public extension Data {
    /// Space-separated lowercase hex, e.g. "aa bb cc".
    var simbleHex: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
