enum VaultError: Error, Equatable, Sendable {
  case locked
  case signedOut
  case notFound
  case notDownloaded
  case unsupported
  case failed(String)
}
