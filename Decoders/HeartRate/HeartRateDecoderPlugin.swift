import Foundation
import SimBLEDecoderKit

// Bluetooth SIG Heart Rate Measurement (0x2A37). Also the smallest example of a decoder plugin.

@_cdecl("simble_make_decoder_plugin")
public func makeDecoderPlugin() -> UnsafeMutableRawPointer {
    exportDecoderPlugin(HeartRateDecoderPlugin())
}

final class HeartRateDecoderPlugin: DecoderPlugin {
    let name = "Heart Rate"
    let columns: [DecoderColumn] = [
        DecoderColumn(id: "bpm", title: "BPM"),
        DecoderColumn(id: "rr", title: "RR (ms)", isVisibleByDefault: false),
    ]

    func accepts(_ context: PacketContext) -> Bool {
        context.characteristic == "2A37" && context.direction == .fromDevice
    }

    func makeDecoder(for context: PacketContext) -> PacketDecoder {
        HeartRateMeasurementDecoder()
    }
}

final class HeartRateMeasurementDecoder: PacketDecoder {
    func decode(_ data: Data) -> [DecodedMessage] {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return [] }
        let isWide = flags & 0x01 != 0
        guard bytes.count >= (isWide ? 3 : 2) else {
            return [DecodedMessage(fields: [DecodedField("Problem", "Too short: \(data.simbleHex)")], isError: true)]
        }
        var offset = 1
        let bpm = isWide ? Int(bytes[1]) | Int(bytes[2]) << 8 : Int(bytes[1])
        offset += isWide ? 2 : 1
        var fields: [DecodedField] = [
            DecodedField("Heart rate", "\(bpm) bpm"),
            DecodedField("Sensor contact", flags & 0x04 == 0 ? "not supported" : flags & 0x02 != 0 ? "detected" : "not detected"),
        ]
        if flags & 0x08 != 0, bytes.count >= offset + 2 {
            fields.append(DecodedField("Energy expended", "\(Int(bytes[offset]) | Int(bytes[offset + 1]) << 8) kJ"))
            offset += 2
        }
        var intervals: [String] = []
        if flags & 0x10 != 0 {
            while bytes.count >= offset + 2 {
                // RR intervals are in 1/1024 s.
                let raw = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                intervals.append("\(raw * 1000 / 1024)")
                offset += 2
            }
            fields.append(DecodedField("RR intervals", intervals.joined(separator: ", ") + " ms"))
        }
        return [DecodedMessage(columns: ["bpm": "\(bpm)", "rr": intervals.joined(separator: ", ")], fields: fields)]
    }
}
