import Foundation
import Darwin

/// One advisory lock per app container, released automatically on exit/crash.
/// Launch Services normally reuses the app; this also covers direct executables
/// and overlapping launches. Never unlink the file while another launch may hold it.
final class AppInstanceLease {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire(directory: URL? = nil) throws -> AppInstanceLease? {
        let storage: URL
        if let directory { storage = directory }
        else {
            storage = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true).appendingPathComponent("Spriglet", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let descriptor = open(storage.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return AppInstanceLease(descriptor: descriptor)
    }
}
