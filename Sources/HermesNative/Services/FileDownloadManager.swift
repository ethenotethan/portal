import Foundation
import os.log

private let log = Logger(subsystem: "com.hermes-native", category: "FileDownload")

/// Manages downloading of remote file attachments with progress tracking.
/// Each attachment download is tracked by its UUID, and progress/result
/// updates are published for the UI to observe.
@MainActor
final class FileDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {

    // MARK: - Published State

    /// Maps attachment UUID → download state. The owning view binds to this for UI updates.
    @Published var states: [UUID: FileAttachment.DownloadState] = [:]

    /// Maps attachment UUID → download progress (0.0–1.0), for progress bar/ring.
    @Published var progress: [UUID: Double] = [:]

    // MARK: - Private

    /// Maps download task identifiers → attachment UUID.
    private var taskToAttachmentID: [Int: UUID] = [:]

    /// Maps attachment UUID → continuation for async-await bridging.
    private var continuations: [UUID: CheckedContinuation<Data, Error>] = [:]

    /// URLSession used for download tasks (owned by this manager).
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Public API

    /// Start downloading a remote file for a given attachment.
    /// - Parameters:
    ///   - url: The remote URL to download from.
    ///   - token: Bearer token for authorization.
    ///   - attachmentID: The UUID of the attachment being downloaded.
    func fetch(url: URL, token: String, attachmentID: UUID) async throws -> Data {
        log.info("Starting download for attachment \(attachmentID): \(url.lastPathComponent)")

        // Mark as downloading
        states[attachmentID] = .downloading(progress: 0)
        progress[attachmentID] = 0

        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return try await withCheckedThrowingContinuation { continuation in
            continuations[attachmentID] = continuation

            let task = urlSession.downloadTask(with: request)
            taskToAttachmentID[task.taskIdentifier] = attachmentID
            task.resume()
        }
    }

    /// Cancel an in-progress download for an attachment.
    func cancel(attachmentID: UUID) {
        log.info("Cancelling download for attachment \(attachmentID)")

        for (taskID, attID) in taskToAttachmentID where attID == attachmentID {
            urlSession.getAllTasks { tasks in
                for task in tasks where task.taskIdentifier == taskID {
                    task.cancel()
                }
            }
            taskToAttachmentID.removeValue(forKey: taskID)
            break
        }

        states[attachmentID] = .notStarted
        progress[attachmentID] = nil

        if let continuation = continuations.removeValue(forKey: attachmentID) {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Reset state for an attachment (e.g., after a failed download, allow retry).
    func reset(attachmentID: UUID) {
        states[attachmentID] = .notStarted
        progress[attachmentID] = nil
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progressValue: Double
        if totalBytesExpectedToWrite > 0 {
            progressValue = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progressValue = 0
        }

        Task { @MainActor in
            guard let attachmentID = taskToAttachmentID[downloadTask.taskIdentifier] else { return }
            self.progress[attachmentID] = progressValue
            self.states[attachmentID] = .downloading(progress: progressValue)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        Task { @MainActor in
            guard let attachmentID = taskToAttachmentID[downloadTask.taskIdentifier] else { return }

            do {
                let data = try Data(contentsOf: location)
                log.info("Download complete for attachment \(attachmentID): \(data.count) bytes")

                self.states[attachmentID] = .ready(data: data)
                self.progress[attachmentID] = 1.0
                self.taskToAttachmentID.removeValue(forKey: downloadTask.taskIdentifier)

                // Persist to disk cache so file survives app restarts
                let fileExtension = downloadTask.originalRequest?.url?.pathExtension ?? downloadTask.currentRequest?.url?.pathExtension ?? "dat"
                FileAttachment.persistToCache(id: attachmentID, data: data, fileExtension: fileExtension)

                if let continuation = self.continuations.removeValue(forKey: attachmentID) {
                    continuation.resume(returning: data)
                }
            } catch {
                log.error("Failed to read downloaded data for attachment \(attachmentID): \(error)")
                self.states[attachmentID] = .failed(error: error.localizedDescription)
                self.taskToAttachmentID.removeValue(forKey: downloadTask.taskIdentifier)

                if let continuation = self.continuations.removeValue(forKey: attachmentID) {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }

        Task { @MainActor in
            guard let attachmentID = taskToAttachmentID[task.taskIdentifier] else { return }

            let nsError = error as NSError
            // Ignore cancellation errors
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                taskToAttachmentID.removeValue(forKey: task.taskIdentifier)
                return
            }

            log.error("Download failed for attachment \(attachmentID): \(error.localizedDescription)")

            // Check HTTP status for more detail
            var errorMessage = error.localizedDescription
            if let httpResponse = task.response as? HTTPURLResponse,
               httpResponse.statusCode >= 400 {
                errorMessage = "HTTP \(httpResponse.statusCode): \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))"
            }

            self.states[attachmentID] = .failed(error: errorMessage)
            self.taskToAttachmentID.removeValue(forKey: task.taskIdentifier)

            if let continuation = self.continuations.removeValue(forKey: attachmentID) {
                continuation.resume(throwing: error)
            }
        }
    }
}
