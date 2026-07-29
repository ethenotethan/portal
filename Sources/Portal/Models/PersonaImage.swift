import SwiftUI
import os

private let personaImageLog = Logger(subsystem: "com.ethenotethan.Portal", category: "PersonaImage")

/// Load and store persona avatar images on disk.
///
/// Avatars can't live inside `SavedGateway` (it's persisted in the Keychain as
/// JSON — binary bytes don't belong there), so an uploaded picture is copied
/// into `~/.hermes/images` and only its *path* is stored on the gateway. This
/// mirrors how chat attachments are cached (`ChatView.gatewayImagesDir`).
internal enum PersonaImage {

    /// Directory for persisted persona/gateway avatar images.
    private static var imagesDir: String {
        let dir = "\(NSHomeDirectory())/.hermes/images"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            personaImageLog.error("persona images dir create failed: \(error.localizedDescription)")
        }
        return dir
    }

    /// Load an image at `path` into a SwiftUI `Image`, or `nil` if it's missing
    /// or undecodable. Platform-split because `NSImage`/`UIImage` differ.
    internal static func load(path: String) -> Image? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        #if os(macOS)
        guard let nsImage = NSImage(contentsOfFile: path) else { return nil }
        return Image(nsImage: nsImage)
        #else
        guard let uiImage = UIImage(contentsOfFile: path) else { return nil }
        return Image(uiImage: uiImage)
        #endif
    }

    /// Copy an on-disk image file into the persona images directory, returning
    /// the destination path, or `nil` on failure. Used by the gateway avatar
    /// picker after the user chooses a file / drops one in.
    internal static func store(fileURL: URL) -> String? {
        let ext = fileURL.pathExtension.isEmpty ? "png" : fileURL.pathExtension
        let dest = "\(imagesDir)/persona-\(UUID().uuidString).\(ext)"
        do {
            try FileManager.default.copyItem(atPath: fileURL.path, toPath: dest)
            return dest
        } catch {
            personaImageLog.error("persona image copy failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Write raw image bytes (e.g. from a `PhotosPicker` selection) into the
    /// persona images directory, returning the destination path, or `nil`.
    internal static func store(data: Data, ext: String = "png") -> String? {
        let dest = "\(imagesDir)/persona-\(UUID().uuidString).\(ext)"
        do {
            try data.write(to: URL(fileURLWithPath: dest))
            return dest
        } catch {
            personaImageLog.error("persona image write failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Best-effort delete of a previously-stored avatar (when the user replaces
    /// or clears it). Silently ignores a missing file.
    internal static func remove(path: String?) {
        guard let path, !path.isEmpty else { return }
        // Only ever remove files we own, under the persona images dir.
        guard path.hasPrefix(imagesDir), FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            personaImageLog.error("persona image delete failed: \(error.localizedDescription)")
        }
    }
}
