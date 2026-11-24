import Foundation

/// A zip archive built in memory, its files stored as they are (no compression: the pictures in it are JPEGs, already compressed). The run export
/// (`AppModel.runExport`) is one: the person shares it from the Activity page and nothing is written to the phone's files (docs/STORAGE.md).
public enum StoredZip {
    /// The archive holding `files` in order. Names are kept to letters, digits, `.`, `-` and `_` (anything else becomes `-`).
    public static func make(_ files: [(name: String, data: Data)], date: Date = Date()) -> Data {
        var out = Data(), central = Data()
        let (time, day) = dosTime(date)
        for file in files {
            let name = Data(safeName(file.name).utf8)
            let crc = crc32(file.data), size = UInt32(file.data.count), offset = UInt32(out.count)
            // Local file header.
            out.le32(0x0403_4b50); out.le16(20); out.le16(0); out.le16(0); out.le16(time); out.le16(day)
            out.le32(crc); out.le32(size); out.le32(size); out.le16(UInt16(name.count)); out.le16(0)
            out.append(name); out.append(file.data)
            // Its entry in the central directory.
            central.le32(0x0201_4b50); central.le16(20); central.le16(20); central.le16(0); central.le16(0); central.le16(time); central.le16(day)
            central.le32(crc); central.le32(size); central.le32(size); central.le16(UInt16(name.count)); central.le16(0); central.le16(0)
            central.le16(0); central.le16(0); central.le32(0); central.le32(offset)
            central.append(name)
        }
        let start = UInt32(out.count)
        out.append(central)
        // End of central directory.
        out.le32(0x0605_4b50); out.le16(0); out.le16(0); out.le16(UInt16(files.count)); out.le16(UInt16(files.count))
        out.le32(UInt32(central.count)); out.le32(start); out.le16(0)
        return out
    }

    /// A file name safe in any archive tool: letters, digits, `.`, `-` and `_`.
    public static func safeName(_ name: String) -> String {
        String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") ? $0 : "-" })
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return ~crc
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func dosTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(shift)) & 0xFF)) } }
}
