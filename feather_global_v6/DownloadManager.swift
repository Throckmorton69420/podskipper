//
//  enum.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import Foundation
import Combine
import UIKit.UIImpactFeedbackGenerator
import BackgroundTasks

class Download: Identifiable, @unchecked Sendable {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0
	
	var overallProgress: Double {
		onlyArchiving
		? unpackageProgress
		: (0.3 * unpackageProgress) + (0.7 * progress)
	}
	
	var task: URLSessionDownloadTask?
	var resumeData: Data?
	
	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
	var sourceProvenance: SourceAppProvenance?
	
	init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false,
		sourceProvenance: SourceAppProvenance? = nil
	) {
		self.id = id
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.sourceProvenance = sourceProvenance
		self.fileName = url.lastPathComponent
	}
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()
	
	@Published var downloads: [Download] = []
	
	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}
	
	private var _session: URLSession!
	private let _progressThrottle = UpdaterProgressThrottle()
	
	#if !targetEnvironment(macCatalyst)
	private func _updateBackgroundAudioState() {
		if #unavailable(iOS 26.0){
			if !downloads.isEmpty {
				BackgroundAudioManager.shared.start()
			} else  {
				BackgroundAudioManager.shared.stop()
			}
		}
	}
	#endif
	
	override init() {
		super.init()
		let configuration = URLSessionConfiguration.default
		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
	}
	
	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		sourceProvenance: SourceAppProvenance? = nil
	) -> Download {
		let requiresUniqueUpdaterCorrelation = id.hasPrefix("FeatherManualDownload_Update_")
		if !requiresUniqueUpdaterCorrelation,
			let existingDownload = downloads.first(where: { existing in
			guard existing.url == url else { return false }
			
			switch (existing.sourceProvenance, sourceProvenance) {
			case (nil, nil):
				return true
			case let (existingProvenance?, requestedProvenance?):
				return existingProvenance.sourceVersionID == requestedProvenance.sourceVersionID
			default:
				return false
			}
		}) {
			resumeDownload(existingDownload)
			return existingDownload
		}
		
		let download = Download(id: id, url: url, sourceProvenance: sourceProvenance)
		
		let task = _session.downloadTask(with: url)
		download.task = task
		task.resume()
		
		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: id, filename: url.lastPathComponent)
		} else {
			_updateBackgroundAudioState()
		}
		#endif
		
		return download
	}
	
	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif
		
		return download
	}
	
	func resumeDownload(_ download: Download) {
		if let resumeData = download.resumeData {
			let task = _session.downloadTask(withResumeData: resumeData)
			download.task = task
			task.resume()
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		} else if let url = download.task?.originalRequest?.url {
			let task = _session.downloadTask(with: url)
			download.task = task
			task.resume()
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		}
	}
	
	private func _notifyUpdaterDownloadTerminated(
		_ download: Download,
		error: String? = nil
	) {
		guard download.id.hasPrefix("FeatherManualDownload_Update_") else { return }
		
		DispatchQueue.main.async {
			var userInfo: [String: Any]? = nil
			if let error {
				userInfo = ["error": error]
			}
			NotificationCenter.default.post(
				name: Notification.Name("Feather.GlobalUpdater.DownloadTerminated"),
				object: download.id,
				userInfo: userInfo
			)
		}
	}
	
	func cancelDownload(_ download: Download) {
		if let task = download.task { _progressThrottle.remove(String(task.taskIdentifier)) }
		download.task?.cancel()
		_notifyUpdaterDownloadTerminated(download)
		
		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
			downloads.remove(at: index)
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()

			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
			}
			#endif
		}
	}
	
	func isManualDownload(_ string: String) -> Bool {
		return string.contains("FeatherManualDownload")
	}
	
	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}
	
	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}
	
	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		return downloads.first(where: { $0.task == task })
	}
}

extension DownloadManager: URLSessionDownloadDelegate {
	
	func handlePachageFile(url: URL, dl: Download) throws {
		FR.handlePackageFile(url, download: dl) { err in
			if let err {
				let generator = UINotificationFeedbackGenerator()
				generator.notificationOccurred(.error)
				self._notifyUpdaterDownloadTerminated(dl, error: err.localizedDescription)
			}

			let downloadsRoot = FileManager.default.temporaryDirectory
				.appendingPathComponent("FeatherDownloads", isDirectory: true)
				.standardizedFileURL.path + "/"
			if url.standardizedFileURL.path.hasPrefix(downloadsRoot) {
				try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
			}
			
			DispatchQueue.main.async {
				if let index = DownloadManager.shared.getDownloadIndex(by: dl.id) {
					DownloadManager.shared.downloads.remove(at: index)
					
					#if !targetEnvironment(macCatalyst)
					if #available(iOS 26.0, *) {
						BackgroundTaskManager.shared.stopTask(for: dl.id, success: err == nil)
					}
					
					self._updateBackgroundAudioState()
					#endif
				}
			}
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		var matchingDownload: Download?
		DispatchQueue.main.sync {
			matchingDownload = getDownloadTask(by: downloadTask)
		}
		guard let download = matchingDownload else { return }

		if
			let response = downloadTask.response as? HTTPURLResponse,
			!(200...299).contains(response.statusCode)
		{
			_notifyUpdaterDownloadTerminated(
				download,
				error: "The server returned HTTP \(response.statusCode)."
			)
			DispatchQueue.main.async {
				if let index = self.getDownloadIndex(by: download.id) {
					self.downloads.remove(at: index)
				}
				#if !targetEnvironment(macCatalyst)
				self._updateBackgroundAudioState()
				if #available(iOS 26.0, *) {
					BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
				}
				#endif
			}
			return
		}
		
		let tempDirectory = FileManager.default.temporaryDirectory
		let customTempDir = tempDirectory
			.appendingPathComponent("FeatherDownloads", isDirectory: true)
			.appendingPathComponent(download.id, isDirectory: true)
		
		do {
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			
			// Use the server-suggested filename if available, otherwise fallback
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
			let destinationURL = customTempDir.appendingPathComponent(suggestedFileName)
			
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)
			
			try handlePachageFile(url: destinationURL, dl: download)
		} catch {
			print("Error handling downloaded file: \(error.localizedDescription)")
			try? FileManager.default.removeItem(at: customTempDir)
			_notifyUpdaterDownloadTerminated(download, error: error.localizedDescription)
			
			DispatchQueue.main.async {
				if let index = self.getDownloadIndex(by: download.id) {
					self.downloads.remove(at: index)
				}
				
				#if !targetEnvironment(macCatalyst)
				self._updateBackgroundAudioState()
				if #available(iOS 26.0, *) {
					BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
				}
				#endif
			}
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		// Coalesce before dispatching, not after thousands of callbacks have
		// already queued main-thread updates and Live Activity requests.
		guard _progressThrottle.shouldPublish(String(downloadTask.taskIdentifier),
			complete: totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite) else { return }
		DispatchQueue.main.async {
			guard let download = self.getDownloadTask(by: downloadTask) else { return }
			download.progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
			: 0
			download.bytesDownloaded = totalBytesWritten
			download.totalBytes = totalBytesExpectedToWrite
			
			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
			}
			#endif
		}
	}
	
	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		_progressThrottle.remove(String(task.taskIdentifier))
		DispatchQueue.main.async {
			guard
				let error,
				let downloadTask = task as? URLSessionDownloadTask,
				let download = self.getDownloadTask(by: downloadTask)
			else {
				return
			}
		
			self._notifyUpdaterDownloadTerminated(
				download,
				error: (error as NSError).code == NSURLErrorCancelled
					? nil
					: error.localizedDescription
			)
		
			if let index = self.getDownloadIndex(by: download.id) {
				self.downloads.remove(at: index)
			}
			
			#if !targetEnvironment(macCatalyst)
			self._updateBackgroundAudioState()
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
			}
			#endif
		}
	}
}
