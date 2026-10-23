import LinkKit
import UIKit

enum PlaidLinkError: LocalizedError {
    case couldNotStart(String)
    case exited(String)

    var errorDescription: String? {
        switch self {
        case .couldNotStart(let message): "Couldn't open bank linking: \(message)"
        case .exited(let message): message
        }
    }
}

/// Opens Plaid Link and returns the public token when the user finishes, or
/// nil when they close it without linking.
@MainActor
final class PlaidLinkPresenter {
    struct Linked {
        var publicToken: String
        var institutionName: String
    }

    // Plaid requires the handler to stay alive while Link is on screen.
    private var handler: Handler?

    func present(linkToken: String) async throws -> Linked? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Linked?, Error>) in
            var finished = false
            let finish: (Result<Linked?, Error>) -> Void = { [weak self] result in
                guard !finished else { return }
                finished = true
                self?.handler = nil
                continuation.resume(with: result)
            }

            var config = LinkTokenConfiguration(token: linkToken) { success in
                finish(.success(Linked(publicToken: success.publicToken,
                                       institutionName: success.metadata.institution.name)))
            }
            config.onExit = { exit in
                if let error = exit.error {
                    finish(.failure(PlaidLinkError.exited(error.displayMessage ?? error.errorMessage)))
                } else {
                    finish(.success(nil))
                }
            }

            switch Plaid.create(config) {
            case .failure(let error):
                finish(.failure(PlaidLinkError.couldNotStart(String(describing: error))))
            case .success(let handler):
                guard let presenter = UIApplication.shared.topViewController else {
                    finish(.failure(PlaidLinkError.couldNotStart("no window to present from")))
                    return
                }
                self.handler = handler
                handler.open(presentUsing: .viewController(presenter))
            }
        }
    }
}

extension UIApplication {
    var topViewController: UIViewController? {
        let window = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
