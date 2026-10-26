import Foundation
import SkyEyeCore

guard CommandLine.arguments.count == 2 else { exit(2) }
do {
    let writer = try RotatingLogWriter(log: URL(fileURLWithPath: CommandLine.arguments[1]))
    while let data = try FileHandle.standardInput.read(upToCount: 64 * 1024), !data.isEmpty {
        try writer.append(data)
    }
} catch {
    FileHandle.standardError.write(Data("SkyEye log writer: \(error.localizedDescription)\n".utf8))
    exit(1)
}
