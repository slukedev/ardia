enum VaultFillError: String, Error, Sendable {
  case locked
  case originMismatch
  case insecure
  case notFound
  case notDownloaded
  case failed
  case notAuthorized
}
