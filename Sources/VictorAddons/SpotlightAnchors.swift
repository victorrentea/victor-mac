import Foundation
import CoreServices

/// ⚓ Keeps files under `~/My Drive` in the Spotlight index.
///
/// Google Drive (mirror mode) uploads a changed file through a temporary **hard link** in
/// `~/My Drive/.tmp.driveupload/<n>`, which it deletes after the upload. When that link is
/// unlinked, mds drops the whole inode from its index (macOS 26.7.1; reproduces without
/// Drive: `ln f .hidden/x; rm .hidden/x`), and with it what Spotlight had learned about the
/// file — so the deck saved a minute ago is the one ⌘Space cannot find (2026-11-18).
///
/// A second, permanent hard link ("anchor") in a folder Spotlight does not look at keeps the
/// entry alive through that unlink (3 → 2 links instead of 2 → 1). So: every file changed
/// under My Drive gets an anchor at once, before Drive removes its own link (~7 s later at
/// the earliest). PowerPoint saves into a new inode each time, which is why this watches
/// the folder instead of anchoring a file once.
final class SpotlightAnchors {
    static let watched = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("My Drive")
    static let anchorsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VictorAddons/spotlight-anchors.noindex")

    private let queue = DispatchQueue(label: "ro.victorrentea.spotlight-anchors", qos: .utility)
    private var stream: FSEventStreamRef?

    /// Which paths get an anchor: real documents only. Drive's own staging, dotfiles, Office
    /// lock files and the 0-byte `Icon\r` markers Drive rewrites by the thousand on start
    /// are left alone. Pure, so it is unit-tested.
    static func wantsAnchor(path: String, root: String) -> Bool {
        guard path.hasPrefix(root + "/") else { return false }
        let parts = path.dropFirst(root.count + 1).split(separator: "/")
        guard let name = parts.last else { return false }
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if name.hasPrefix("~$") || name == "Icon\r" { return false }
        return true
    }

    /// Anchor name: the inode. One anchor per inode, and a stale one is recognisable.
    static func anchorName(inode: UInt64) -> String { String(inode) }

    func start() {
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: Self.anchorsDir, withIntermediateDirectories: true)
            Self.prune()
            var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
            let cb: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let me = Unmanaged<SpotlightAnchors>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                for i in 0..<min(count, list.count)
                where flags[i] & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 {
                    me.anchor(list[i])
                }
            }
            let fl = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                            | kFSEventStreamCreateFlagNoDefer)
            guard let s = FSEventStreamCreate(nil, cb, &ctx, [Self.watched.path] as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, fl) else {
                overlayError("SpotlightAnchors: could not watch \(Self.watched.path)")
                return
            }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
    }

    /// Runs on `queue`.
    private func anchor(_ path: String) {
        guard Self.wantsAnchor(path: path, root: Self.watched.path) else { return }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else { return }
        let dest = Self.anchorsDir.appendingPathComponent(Self.anchorName(inode: UInt64(st.st_ino))).path
        if link(path, dest) != 0 {
            if errno == EEXIST { return }
            NSLog("SpotlightAnchors: link failed for %@: %s", path, strerror(errno))
            return
        }
        // Already dropped by an earlier sync (or never indexed): hand it back once.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
        p.arguments = [path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        if Int.random(in: 0..<50) == 0 { Self.prune() }
    }

    /// An anchor that is the last link to its inode (the original was deleted or replaced by
    /// a save) only holds disk space: remove it. Never remove one whose original is alive —
    /// that unlink would drop the file from the index again.
    static func prune(dir: URL = SpotlightAnchors.anchorsDir) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names {
            let p = dir.appendingPathComponent(n).path
            var st = stat()
            if lstat(p, &st) == 0, st.st_nlink == 1 { unlink(p) }
        }
    }
}
