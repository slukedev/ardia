import Testing

@main struct SwiftTestingRunner {
  static func main() async {
    await Testing.__swiftPMEntryPoint() as Never
  }
}
