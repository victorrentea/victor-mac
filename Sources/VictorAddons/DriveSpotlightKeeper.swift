import Foundation
import CoreServices

/// 🔎 Keeps files under `~/My Drive` in the Spotlight index.
///
/// Google Drive (mirror mode) uploads a changed file through a temporary **hard link** in
/// `~/My Drive/.tmp.driveupload/<n>`, which it deletes after the upload. When that link is
/// unlinked, mds drops the whole inode from its index (macOS 26.7.1; reproduces without
/// Drive: `ln f .hidden/x; rm .hidden/x`) — so the deck saved a minute ago is the one
/// ⌘Space cannot find (2026-11-18).
///
/// So: every file changed under My Drive is handed back with `mdimport` once Drive has
/// removed its link (link count back to 1).
///
/// The first version kept a permanent second hard link ("anchor") instead, which does keep
/// the entry alive through the unlink — but PowerPoint then refused to save the deck
/// ("The document could not be saved", 2026-11-18): never hard-link a user's document.
final class DriveSpotlightKeeper {
    static let watched = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("My Drive")
    /// Drive creates its link within a second of the change and holds it for the upload.
    static let firstCheck: TimeInterval = 6
    static let recheck: TimeInterval = 4
    /// A big upload on a slow network: give up after 20 min rather than poll forever.
    static let maxChecks = 300

    private let queue = DispatchQueue(label: "ro.victorrentea.drive-spotlight-keeper", qos: .utility)
    private var stream: FSEventStreamRef?
    /// Paths with a check already scheduled.
    private var pending: Set<String> = []

    /// Which paths are handed back: real documents only. Drive's own staging, dotfiles, Office
    /// lock files and the 0-byte `Icon\r` markers Drive rewrites by the thousand on start
    /// are left alone. Pure, so it is unit-tested.
    static func wantsReimport(path: String, root: String) -> Bool {
        guard path.hasPrefix(root + "/") else { return false }
        let parts = path.dropFirst(root.count + 1).split(separator: "/")
        guard let name = parts.last else { return false }
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if name.hasPrefix("~$") || name == "Icon\r" { return false }
        return true
    }

    func start() {
        queue.async { [self] in
            var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
            let cb: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let me = Unmanaged<DriveSpotlightKeeper>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                for i in 0..<min(count, list.count)
                where flags[i] & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 {
                    me.changed(list[i])
                }
            }
            let fl = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
            guard let s = FSEventStreamCreate(nil, cb, &ctx, [Self.watched.path] as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, fl) else {
                overlayError("DriveSpotlightKeeper: could not watch \(Self.watched.path)")
                return
            }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
    }

    /// Runs on `queue`.
    private func changed(_ path: String) {
        guard Self.wantsReimport(path: path, root: Self.watched.path), !pending.contains(path) else { return }
        pending.insert(path)
        check(path, left: Self.maxChecks, after: Self.firstCheck)
    }

    private func check(_ path: String, left: Int, after: TimeInterval) {
        queue.asyncAfter(deadline: .now() + after) { [self] in
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else {
                pending.remove(path)
                return
            }
            if st.st_nlink > 1, left > 0 {
                check(path, left: left - 1, after: Self.recheck)
                return
            }
            pending.remove(path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
            p.arguments = [path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }
}
