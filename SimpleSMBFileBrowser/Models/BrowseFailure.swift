import Foundation

/// A connection or browse failure, translated into something worth showing a
/// person.
///
/// AMSMB2 surfaces everything as `POSIXError` (see `Context.swift` in the
/// package — it calls `POSIXError.throwIfError` on libsmb2 return codes), so
/// this type is the single place raw `errno` values become sentences. Anything
/// unrecognised keeps the underlying description rather than being flattened
/// into a useless "unknown error".
struct BrowseFailure: Equatable, Sendable, Identifiable, Error {
    enum Kind: Equatable, Sendable {
        case timedOut
        case hostUnreachable
        case connectionRefused
        case authenticationFailed
        case shareNotFound
        case permissionDenied
        case notFound
        case alreadyExists
        case directoryNotEmpty
        case outOfSpace
        case invalidConfiguration
        case cancelled
        case other
    }

    let id = UUID()
    let kind: Kind
    /// What the failure relates to — an SMB host, or a device location name
    /// such as "iCloud Drive". Used to make messages specific.
    let target: String
    /// Raw description from the underlying error, kept for the details row.
    let underlyingDescription: String?

    init(kind: Kind, target: String, underlyingDescription: String? = nil) {
        self.kind = kind
        self.target = target
        self.underlyingDescription = underlyingDescription
    }

    static func == (lhs: BrowseFailure, rhs: BrowseFailure) -> Bool {
        lhs.kind == rhs.kind
            && lhs.target == rhs.target
            && lhs.underlyingDescription == rhs.underlyingDescription
    }
}

// MARK: - Mapping from underlying errors

extension BrowseFailure {
    /// Translates a local filesystem error, where EACCES means "no permission
    /// to this file" rather than "the server rejected your credentials".
    init(localError error: any Error, target: String) {
        let mapped = BrowseFailure(error: error, target: target)
        self.init(
            kind: mapped.kind == .authenticationFailed ? .permissionDenied : mapped.kind,
            target: target,
            underlyingDescription: mapped.underlyingDescription
        )
    }

    /// Translates an error thrown by AMSMB2 (or Foundation) into a failure.
    init(error: any Error, target: String) {
        if let failure = error as? BrowseFailure {
            self = failure
            return
        }
        if error is CancellationError {
            self.init(kind: .cancelled, target: target)
            return
        }

        let description: String?
        let code: POSIXErrorCode?

        if let posix = error as? POSIXError {
            code = posix.code
            description = (error as NSError).localizedDescription
        } else {
            let nsError = error as NSError
            description = nsError.localizedDescription
            if nsError.domain == NSPOSIXErrorDomain {
                code = POSIXErrorCode(rawValue: Int32(nsError.code))
            } else if nsError.domain == NSCocoaErrorDomain {
                // FileManager reports through Cocoa codes, which is how the
                // Device Files locations surface failures.
                switch nsError.code {
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                    code = .ENOENT
                case NSFileWriteFileExistsError:
                    code = .EEXIST
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                    code = .EACCES
                case NSFileWriteOutOfSpaceError:
                    code = .ENOSPC
                case NSFileWriteVolumeReadOnlyError:
                    code = .EROFS
                case NSUserCancelledError:
                    code = .ECANCELED
                default:
                    // Fall back to the POSIX error Cocoa wrapped, if any.
                    let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                    code = underlying?.domain == NSPOSIXErrorDomain
                        ? POSIXErrorCode(rawValue: Int32(underlying!.code))
                        : nil
                }
            } else if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorTimedOut: code = .ETIMEDOUT
                case NSURLErrorCannotFindHost: code = .EHOSTUNREACH
                case NSURLErrorCannotConnectToHost: code = .ECONNREFUSED
                case NSURLErrorUserAuthenticationRequired: code = .EACCES
                case NSURLErrorCancelled: code = nil
                default: code = nil
                }
            } else {
                code = nil
            }
        }

        self.init(kind: Self.kind(for: code), target: target, underlyingDescription: description)
    }

    private static func kind(for code: POSIXErrorCode?) -> Kind {
        guard let code else { return .other }
        switch code {
        case .ETIMEDOUT: return .timedOut
        case .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH, .ENETDOWN: return .hostUnreachable
        case .ECONNREFUSED: return .connectionRefused
        // libsmb2 reports a rejected NTLM session as EACCES; EPERM and
        // ENOTCONN show up depending on where in the handshake it fails.
        case .EACCES, .EPERM, .EAUTH, .ENOTCONN, .ECONNRESET: return .authenticationFailed
        case .ENODEV, .ENXIO: return .shareNotFound
        case .EROFS: return .permissionDenied
        case .ENOENT: return .notFound
        case .EEXIST: return .alreadyExists
        case .ENOTEMPTY: return .directoryNotEmpty
        case .ENOSPC, .EDQUOT: return .outOfSpace
        case .EINVAL: return .invalidConfiguration
        case .ECANCELED: return .cancelled
        default: return .other
        }
    }
}

// MARK: - Presentation

extension BrowseFailure {
    var title: String {
        switch kind {
        case .timedOut: return "Connection Timed Out"
        case .hostUnreachable: return "Server Unreachable"
        case .connectionRefused: return "Connection Refused"
        case .authenticationFailed: return "Sign-In Failed"
        case .shareNotFound: return "Share Not Found"
        case .permissionDenied: return "Permission Denied"
        case .notFound: return "Not Found"
        case .alreadyExists: return "Item Already Exists"
        case .directoryNotEmpty: return "Folder Not Empty"
        case .outOfSpace: return "Out of Space"
        case .invalidConfiguration: return "Invalid Connection Details"
        case .cancelled: return "Cancelled"
        case .other: return "Couldn't Connect"
        }
    }

    /// The user-facing explanation. Phrased to name the target, because
    /// "timed out" alone doesn't tell anyone which machine went quiet.
    var message: String {
        let label = target.isEmpty ? "the server" : target
        switch kind {
        case .timedOut:
            return "Couldn't reach \(label) — the connection timed out. Check that the server is powered on and on the same network, and that any VPN or tunnel you need is connected."
        case .hostUnreachable:
            return "\(label) couldn't be found on the network. Check the address, and whether you need a VPN or tunnel to reach it."
        case .connectionRefused:
            return "\(label) refused the connection. File sharing may be turned off, or SMB may be listening on a different port."
        case .authenticationFailed:
            return "\(label) rejected the username or password. Check your credentials and try again."
        case .shareNotFound:
            return "\(label) is reachable, but the share couldn't be opened. Check the share name."
        case .permissionDenied:
            return "You don't have permission to do that on \(label)."
        case .notFound:
            return "That item no longer exists on \(label)."
        case .alreadyExists:
            return "An item with that name already exists."
        case .directoryNotEmpty:
            return "That folder still has items in it."
        case .outOfSpace:
            return "There isn't enough free space on \(label)."
        case .invalidConfiguration:
            return "The connection details for \(label) aren't valid. Check the host, port, and share name."
        case .cancelled:
            return "The operation was cancelled."
        case .other:
            return underlyingDescription.map { "Couldn't connect to \(label). \($0)" }
                ?? "Couldn't connect to \(label)."
        }
    }

    var symbolName: String {
        switch kind {
        case .timedOut, .hostUnreachable: return "wifi.exclamationmark"
        case .connectionRefused: return "bolt.horizontal.circle"
        case .authenticationFailed: return "person.crop.circle.badge.exclamationmark"
        case .shareNotFound, .notFound: return "questionmark.folder"
        case .permissionDenied: return "lock.fill"
        case .alreadyExists, .directoryNotEmpty: return "exclamationmark.triangle"
        case .outOfSpace: return "externaldrive.badge.exclamationmark"
        case .invalidConfiguration: return "gearshape.badge.xmark"
        case .cancelled: return "xmark.circle"
        case .other: return "exclamationmark.triangle"
        }
    }

    /// Whether editing the connection is a plausible fix — drives which button
    /// the failure modal emphasises.
    var suggestsEditingConnection: Bool {
        switch kind {
        case .authenticationFailed, .shareNotFound, .invalidConfiguration, .connectionRefused:
            return true
        default:
            return false
        }
    }

    /// Whether a VPN/tunnel recovery app is a plausible fix.
    var suggestsRecoveryApp: Bool {
        switch kind {
        case .timedOut, .hostUnreachable, .connectionRefused: return true
        default: return false
        }
    }
}
