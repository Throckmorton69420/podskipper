import Foundation.NSURL
import UIKit.UIImage

extension FR {
	static func signPackageFileReturningUUID(
		_ app: AppInfoPresentable,
		using options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		completion: @escaping (String?, Error?) -> Void
	) {
		Task.detached {
			let handler = SigningHandler(app: app, options: options)
			handler.appCertificate = certificate
			handler.appIcon = icon

			do {
				try await handler.copy()
				try await handler.modify()
				try? await handler.clean()
				let outputUUID = handler.outputUUID
				await MainActor.run {
					completion(outputUUID, nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(nil, error)
				}
			}
		}
	}
}
