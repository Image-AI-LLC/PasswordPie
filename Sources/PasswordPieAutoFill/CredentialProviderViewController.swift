import AuthenticationServices

/// PasswordPie's AutoFill credential provider extension. It exists so Passwords lists PasswordPie as a target for
/// Export All Items to App (Credential Exchange); the import itself runs in the main app. It does not fill
/// credentials, so every AutoFill request is cancelled.
@objc(CredentialProviderViewController)
final class CredentialProviderViewController: ASCredentialProviderViewController {
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain,
            code: ASExtensionError.userCanceled.rawValue
        ))
    }
}
