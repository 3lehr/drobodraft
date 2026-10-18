import Foundation

/// Small pure adapter for SCSI block commands received from the virtual target.
/// The resulting CDB still passes through `ISCSISitzung.verbot` and `befehl` before any send.
public enum BlockCDBAdapter {
    public static func adapt(cdb: [UInt8], dataInLength: Int, dataOutLength: Int, blockSize: Int, lunBlockCount: UInt64) throws -> [UInt8] {
        guard dataInLength >= 0, dataOutLength >= 0,
              dataInLength <= ISCSISitzung.maxDatenmenge, dataOutLength <= ISCSISitzung.maxDatenmenge,
              blockSize > 0, lunBlockCount > 0 else {
            throw ISCSIFehler.verboten("invalid block command lengths")
        }
        guard let opcode = cdb.first else { throw ISCSIFehler.verboten("empty CDB") }
        guard dataInLength == 0 || dataOutLength == 0 else {
            throw ISCSIFehler.verboten("simultaneous data-in and data-out")
        }

        var result = cdb
        switch opcode {
        case 0x28, 0x2A, 0x88, 0x8A: // READ/WRITE(10/16)
            let isTen = opcode == 0x28 || opcode == 0x2A
            guard cdb.count == (isTen ? 10 : 16) else {
                throw ISCSIFehler.verboten("block CDB has invalid length")
            }
            if isTen && cdb[6] & 0xE0 != 0 {
                throw ISCSIFehler.verboten("READ/WRITE(10) reserved bits are set")
            }
            let isWrite = opcode == 0x2A || opcode == 0x8A
            guard isWrite ? (dataInLength == 0 && dataOutLength > 0) : (dataOutLength == 0 && dataInLength > 0) else {
                throw ISCSIFehler.verboten("block command data direction or length is invalid")
            }
            let count: UInt64
            let lba: UInt64
            if isTen {
                lba = cdb[2..<6].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                count = UInt64(cdb[7]) << 8 | UInt64(cdb[8])
            } else {
                lba = cdb[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                count = UInt64(cdb[10]) << 24 | UInt64(cdb[11]) << 16 | UInt64(cdb[12]) << 8 | UInt64(cdb[13])
            }
            guard lba < lunBlockCount, count <= lunBlockCount - lba else {
                throw ISCSIFehler.verboten("block CDB exceeds LUN bounds")
            }
            guard count > 0, count <= UInt64(Int.max / blockSize), Int(count) * blockSize == (isWrite ? dataOutLength : dataInLength) else {
                throw ISCSIFehler.verboten("block CDB transfer count does not match buffer length")
            }

            if isTen {
                result = [UInt8](repeating: 0, count: 16)
                result[0] = isWrite ? 0x8A : 0x88
                result[1] = cdb[1]
                result[2...5] = [0, 0, 0, 0]
                result[6...9] = cdb[2...5]
                result[10] = 0
                result[11] = 0
                result[12] = cdb[7]
                result[13] = cdb[8]
                result[14] = cdb[6] & 0x1F
                result[15] = cdb[9]
            }
        case 0x00, 0x12, 0xA0, 0x9E, 0x5A:
            if dataOutLength != 0 { throw ISCSIFehler.verboten("data-out is not valid for this command") }
            if opcode == 0x00 && dataInLength != 0 { throw ISCSIFehler.verboten("TEST UNIT READY has no data-in") }
        default:
            break // the existing send gate rejects EA, MODE SELECT, vendor and unknown opcodes
        }

        if let reason = ISCSISitzung.verbot(cdb: result, schreiben: dataOutLength, lesen: dataInLength) {
            throw ISCSIFehler.verboten(reason)
        }
        return result
    }
}
