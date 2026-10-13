import Foundation

/// Why a machine can't be reached, in a sentence that says what to do about it. A machine is an aludra host behind
/// `tailscale serve`, so most failures are one of: Tailscale off or the name wrong, tailscale serve not set up, aludra
/// not running behind it, or this login not let in.
public enum ConnectionTrouble {
	public static func explain(_ error: any Error) -> String {
		if let refused = error as? UpgradeRefused { return explain(status: refused.status) }
		if let url = error as? URLError { return explain(url.code) }
		let ns = error as NSError
		if ns.domain == NSURLErrorDomain { return explain(URLError.Code(rawValue: ns.code)) }
		return String(describing: error)
	}

	static func explain(status: Int) -> String {
		switch status {
		case 401:
			"No Tailscale login reached aludra. Connect through tailscale serve, at the machine's .ts.net name."
		case 403:
			"aludra there doesn't let your Tailscale login in. Add it to api.users in its settings (aludra doctor shows them)."
		case 404:
			"Nothing answers at /amyrlin there. Check the address, and that it's aludra behind tailscale serve."
		case 502, 503, 504:
			"tailscale serve is on, but aludra isn't answering behind it. On that machine, run aludra service install, then aludra doctor."
		default:
			"The server refused the connection (HTTP \(status)). On that machine, aludra doctor says what's wrong."
		}
	}

	static func explain(_ code: URLError.Code) -> String {
		switch code {
		case .cannotFindHost, .dnsLookupFailed:
			"That name doesn't resolve. Check that Tailscale is on here and the machine's name is right."
		case .cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
			"Can't reach the machine. Is it on, with Tailscale running and tailscale serve set up (tailscale serve --bg 8724)?"
		case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
			"The HTTPS connection failed. tailscale serve provides it; on that machine, run tailscale serve --bg 8724."
		case .badServerResponse:
			"The server refused the connection. On that machine, aludra doctor says what's wrong."
		default:
			"Can't connect (\(code.rawValue)). On that machine, aludra doctor says what's wrong."
		}
	}
}
