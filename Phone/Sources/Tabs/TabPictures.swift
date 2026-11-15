import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers
import os

/// Every card's picture of its tab's page, for All Tabs and the stack
/// (TabStack.picture), kept past the pool's own (WebPool.snapshots, which
/// last only this run and only while it holds them): small, written to disk
/// off the main thread, read back lazily into a memory cache of limited size,
/// so the cards show real pages after a launch too.
///
/// A picture is the page from the screen's top down to the chrome's row (a
/// card's content area and the strip under the status bar, which the cards
/// show as they grow into the page), as wide as All Tabs' widest card at the
/// screen's scale. Its size in points is the page's: as wide as the screen,
/// whatever its pixels, so it draws where the pool's whole-page pictures do.
///
/// Ordinary tabs' pictures are kept until the tab closes (`prune`) or Clear
/// History and Website Data (`clear`); private tabs' never touch the disk and
/// go as Private locks (`dropPrivate`). Fixture worlds keep them in memory,
/// unless a UI test names a folder (YAB_TAB_PICTURES).
@MainActor
final class TabPictures {
    /// What a picture holds: the page from the screen's top `height` points
    /// down, across the screen's `width`, drawn `pixels` wide.
    struct Shape: Equatable, Sendable {
        var width: CGFloat
        var height: CGFloat
        var pixels: CGFloat

        /// All Tabs' widest card on this screen, at this scale.
        init(layout: TabGalleryLayout, scale: CGFloat) {
            width = layout.screen.width
            height = layout.page.height
            pixels = (layout.pictureWidth * max(1, scale)).rounded()
        }

        init(width: CGFloat, height: CGFloat, pixels: CGFloat) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        /// The picture's size in pixels.
        var size: CGSize {
            CGSize(width: pixels, height: (pixels * height / max(1, width)).rounded())
        }
    }

    /// Where pictures are kept; nil keeps them in memory only.
    let folder: URL?
    /// Decoded pictures kept in memory, in bytes: past it the least recently
    /// drawn go (they come back from the disk). Enough for every card All
    /// Tabs draws at once (TabGalleryLayout.draws) on the largest iPhone.
    let memoryLimit: Int
    /// The screen's pictures, as TabStack sees it.
    var shape: Shape
    /// Told when a picture came or went: cards draw again.
    var onChange: (() -> Void)?

    /// How long a closed tab's picture stays in memory, for Undo (BackStack,
    /// Clear): a tab back by then has it again, on disk too.
    static let closedFor: TimeInterval = 60
    /// A picture drawn this recently isn't let go for room: the cards on
    /// screen keep theirs even when they need more than the limit.
    static let inUse: TimeInterval = 0.5
    nonisolated static let defaultMemoryLimit = 64 << 20
    /// JPEG: as quick to make as to read, everywhere (HEIC's encoder isn't
    /// in every simulator). 0.75 keeps a page's words sharp at card size.
    nonisolated static let quality = 0.75

    private struct Entry {
        var image: UIImage
        var cost: Int
        var isPrivate: Bool
        var used: TimeInterval
        /// The tab closed then (uptime); its picture waits for Undo.
        var closed: TimeInterval?
    }
    private var memory: [Tab.ID: Entry] = [:]
    private(set) var memoryCost = 0
    /// File names on disk.
    private var onDisk: Set<String> = []
    private var names: [Tab.ID: String] = [:]
    private var loading: Set<Tab.ID> = []
    /// Bumped by every change to a tab's picture, so a late write or read
    /// never brings back one that was replaced or removed.
    private var generations: [Tab.ID: Int] = [:]
    private var epoch = 0
    private let queue = DispatchQueue(label: "dev.serafim.fast.iphone.tab-pictures", qos: .utility)
    private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "pictures")

    init(folder: URL?, shape: Shape, memoryLimit: Int = TabPictures.defaultMemoryLimit) {
        self.folder = folder
        self.shape = shape
        self.memoryLimit = memoryLimit
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A folder of a few hundred names: listed once, at once.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        onDisk = Set(files.filter { $0.hasSuffix(".jpg") })
    }

    /// Where this app's pictures are kept: Caches for the person's own
    /// profile (iOS may empty it; the cards then warm up again), beside an
    /// explicit test profile, the folder a UI test names, or nowhere (a
    /// fixture world, in memory).
    static func folder(for app: AppModel, options: LaunchOptions = .current,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if options.isTestRun, let path = environment["YAB_TAB_PICTURES"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let profile = app.profile else { return nil }
        if profile.folder.standardizedFileURL == BrowserProfile.defaultFolder.standardizedFileURL {
            return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TabPictures", isDirectory: true)
        }
        return profile.folder.appendingPathComponent("TabPictures", isDirectory: true)
    }

    // MARK: - reading

    /// The tab's picture when it is in memory now. One kept on disk is read
    /// and decoded off the main thread, and `onChange` says when it is here.
    func image(for id: Tab.ID) -> UIImage? {
        if memory[id] != nil {
            memory[id]?.used = Self.now
            return memory[id]?.image
        }
        load(id)
        return nil
    }

    /// A picture exists for the tab, in memory or on disk.
    func has(_ id: Tab.ID) -> Bool { memory[id] != nil || onDisk.contains(name(id)) }

    /// On disk (tests).
    func isOnDisk(_ id: Tab.ID) -> Bool { onDisk.contains(name(id)) }
    func isInMemory(_ id: Tab.ID) -> Bool { memory[id] != nil }

    private func load(_ id: Tab.ID) {
        guard let folder, !loading.contains(id), onDisk.contains(name(id)) else { return }
        loading.insert(id)
        let url = folder.appendingPathComponent(name(id))
        let generation = generations[id, default: 0], epoch = epoch, width = shape.width
        queue.async {
            let image = Self.decode(url, width: width)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loading.remove(id)
                    guard self.epoch == epoch, self.generations[id, default: 0] == generation, self.memory[id] == nil else { return }
                    guard let image else {
                        // Unreadable: it goes, and the card warms up again.
                        self.log.error("an unreadable picture went")
                        self.onDisk.remove(self.name(id))
                        self.queue.async { try? FileManager.default.removeItem(at: url) }
                        return
                    }
                    self.insert(image, for: id, isPrivate: false)
                    self.onChange?()
                }
            }
        }
    }

    // MARK: - keeping

    /// Keeps `image`, a picture of the page from the screen's top across its
    /// width (the pool's whole page, or a card's capture already cut to it),
    /// cut and scaled to `shape` off the main thread; an ordinary tab's on
    /// disk too. `done` is told once it is in memory (tests).
    func keep(_ image: UIImage, for id: Tab.ID, isPrivate: Bool, done: (() -> Void)? = nil) {
        let generation = generations[id, default: 0] + 1
        generations[id] = generation
        let shape = shape, epoch = epoch
        let url = isPrivate ? nil : folder?.appendingPathComponent(name(id))
        let name = name(id)
        queue.async {
            guard let made = Self.render(image, shape: shape) else {
                DispatchQueue.main.async { done?() }
                return
            }
            let picture = UIImage(cgImage: made, scale: CGFloat(made.width) / shape.width, orientation: .up)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    defer { done?() }
                    guard self.epoch == epoch, self.generations[id] == generation else { return }
                    self.insert(picture, for: id, isPrivate: isPrivate)
                    self.onChange?()
                    guard let url else { return }
                    self.queue.async {
                        guard let data = Self.encode(made) else { return }
                        do {
                            // iOS may have emptied Caches, folder and all.
                            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try data.write(to: url, options: .atomic)
                        } catch {
                            Logger(subsystem: "dev.serafim.fast.iphone", category: "pictures")
                                .error("a picture wasn't written: \(String(describing: error), privacy: .public)")
                            return
                        }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                // Replaced or removed meanwhile: the newer state wins.
                                guard self.epoch == epoch, self.generations[id] == generation else { return }
                                self.onDisk.insert(name)
                            }
                        }
                    }
                }
            }
        }
    }

    private func insert(_ image: UIImage, for id: Tab.ID, isPrivate: Bool) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        if let old = memory[id] { memoryCost -= old.cost }
        memory[id] = Entry(image: image, cost: cost, isPrivate: isPrivate, used: Self.now)
        memoryCost += cost
        trim()
    }

    /// The least recently drawn go until the rest fit, but never one drawn
    /// just now: cards on screen keep theirs.
    func trim(now: TimeInterval = TabPictures.now) {
        while memoryCost > memoryLimit {
            guard let oldest = memory.filter({ now - $0.value.used > Self.inUse })
                .min(by: { $0.value.used < $1.value.used })?.key else { return }
            forgetInMemory(oldest)
        }
    }

    private func forgetInMemory(_ id: Tab.ID) {
        guard let entry = memory.removeValue(forKey: id) else { return }
        memoryCost -= entry.cost
    }

    // MARK: - letting go

    /// The tabs there are now: pictures of tabs gone leave the disk at once;
    /// in memory they wait `closedFor`, and one whose tab came back (Undo) is
    /// written again. True while closed tabs' pictures still wait.
    @discardableResult
    func prune(keeping ids: Set<Tab.ID>, now: TimeInterval = TabPictures.now) -> Bool {
        var waiting = false
        for (id, entry) in memory {
            if ids.contains(id) {
                guard entry.closed != nil else { continue }
                memory[id]?.closed = nil
                if !entry.isPrivate { rewrite(entry.image, for: id) }
            } else if let closed = entry.closed {
                if now - closed >= Self.closedFor {
                    forgetInMemory(id)
                    onChange?()
                } else { waiting = true }
            } else {
                memory[id]?.closed = now
                waiting = true
            }
        }
        let kept = Set(ids.map(name))
        let gone = onDisk.subtracting(kept)
        guard !gone.isEmpty, let folder else { return waiting }
        onDisk.subtract(gone)
        queue.async {
            for file in gone { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
        }
        return waiting
    }

    /// A picture in memory, back on disk (its tab came back).
    private func rewrite(_ image: UIImage, for id: Tab.ID) {
        guard let folder, let made = image.cgImage else { return }
        let url = folder.appendingPathComponent(name(id)), name = name(id)
        let generation = generations[id, default: 0], epoch = epoch
        queue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = Self.encode(made), (try? data.write(to: url, options: .atomic)) != nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.epoch == epoch, self.generations[id, default: 0] == generation else { return }
                    self.onDisk.insert(name)
                }
            }
        }
    }

    /// One tab's picture goes, from memory and disk.
    func remove(_ id: Tab.ID) {
        generations[id, default: 0] += 1
        forgetInMemory(id)
        let file = name(id)
        if onDisk.remove(file) != nil, let folder {
            queue.async { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
        }
        onChange?()
    }

    /// Private's lock closed: its pictures go (they were only ever in memory).
    func dropPrivate() {
        for (id, entry) in memory where entry.isPrivate {
            generations[id, default: 0] += 1
            forgetInMemory(id)
            onChange?()
        }
    }

    /// Clear History and Website Data: every ordinary tab's picture goes,
    /// from memory and disk. Private's stay in memory, as its pages do.
    func clear() {
        epoch += 1
        loading.removeAll()
        for (id, entry) in memory where !entry.isPrivate { forgetInMemory(id) }
        onDisk.removeAll()
        if let folder {
            queue.async {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                for file in files { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
            }
        }
        onChange?()
    }

    /// Waits until every write and removal asked for so far is done (tests,
    /// and a relaunch's UI test).
    func settled() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { DispatchQueue.main.async { done.resume() } }
        }
        // A write's last step comes back to the main queue, and may queue a file.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { DispatchQueue.main.async { done.resume() } }
        }
    }

    // MARK: - files

    /// A tab's file: its id hashed, since ids come from the Mac and worlds.
    func name(_ id: Tab.ID) -> String {
        if let name = names[id] { return name }
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let name = digest + ".jpg"
        names[id] = name
        return name
    }

    nonisolated static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// `image` cut and scaled to the shape: drawn at its width from the top,
    /// what is below the shape's height left out. A capture already that
    /// size is kept as it is.
    nonisolated static func render(_ image: UIImage, shape: Shape) -> CGImage? {
        let size = shape.size
        guard size.width > 0, size.height > 0, image.size.width > 0 else { return nil }
        if let cg = image.cgImage, abs(CGFloat(cg.width) - size.width) <= 1, abs(CGFloat(cg.height) - size.height) <= 2 {
            return cg
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let k = size.width / image.size.width
            image.draw(in: CGRect(x: 0, y: 0, width: size.width, height: image.size.height * k))
        }
        return drawn.cgImage
    }

    nonisolated static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Read and decoded here, not on the main thread as it is first drawn.
    nonisolated static func decode(_ url: URL, width: CGFloat) -> UIImage? {
        guard width > 0, let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image, scale: CGFloat(image.width) / width, orientation: .up)
    }
}
