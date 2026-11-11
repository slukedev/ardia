import AppKit
import ExpoModulesCore

public class VaultsModule: Module {
  public func definition() -> ModuleDefinition {
    Name(Self.calls.moduleName)
    Events(Self.calls.domain)
    Self.calls.forwardEvents(to: self)

    OnCreate {
      VaultAutoLock.shared.start()
      DispatchQueue.main.async { ChromeStoreWatcher.start() }
    }

    Self.calls.function

    AsyncFunction("signIn") { (provider: String, fieldsJSON: String, promise: Promise) in
      let fields = VaultSignInFields(json: fieldsJSON)
      Task {
        guard let result = await VaultBroker.shared.signIn(provider, fields: fields) else {
          return promise.reject("ERR_BAD_ARGS", VaultsModule.unknown(provider))
        }
        promise.resolve(VaultJSON.text(result.jsonObject()))
      }
    }

    AsyncFunction("saveGooglePassword") { (email: String, password: String, promise: Promise) in
      Task {
        let saved = GoogleAccountPassword.save(email: email, password: password)
        promise.resolve(VaultJSON.text(["ok": saved, "error": saved ? "" : "Ardia couldn't keep your Google password in the keychain."]))
      }
    }

    View(VaultTouchIDView.self) {
      Events("onEnded")
      Prop("armed") { (view: VaultTouchIDView, value: Bool?) in view.armed = value ?? false }
    }

    AsyncFunction("unlock") { (provider: String, password: String?, promise: Promise) in
      Task {
        guard let result = await VaultBroker.shared.unlock(provider, password: password) else {
          return promise.reject("ERR_BAD_ARGS", VaultsModule.unknown(provider))
        }
        promise.resolve(VaultJSON.text(result.jsonObject()))
      }
    }
  }

  static func unknown(_ provider: String) -> String { "vaults: \(provider) isn't a password manager Ardia knows" }

  static func provider(_ args: CallArgs) throws -> String {
    let id = try args.text("provider")
    guard VaultRegistry.provider(id) != nil else { throw BadCallArgs(message: "\(id) isn't a password manager Ardia knows") }
    return id
  }

  static func optionalProvider(_ args: CallArgs) throws -> String? {
    guard try args.optionalText("provider") != nil else { return nil }
    return try provider(args)
  }

  static func answer(_ reply: CallReply, _ work: @escaping @Sendable () async -> Any?) {
    Task { reply.ok(await work()) }
  }

  static func googleAccount() -> [String: Any] {
    let email = GoogleAccountPassword.email()
    return ["email": email ?? NSNull(), "hasPassword": email != nil]
  }

  static func copied(_ copied: Bool?) -> [String: Any] {
    guard let copied else { return ["copied": false, "declined": true, "clearsAfter": 0] }
    return ["copied": copied, "clearsAfter": copied ? VaultClipboard.clearDelay : 0]
  }

  static let calls = CallTable(domain: "vaults", handlers: [
    "providers": { _, reply in VaultsModule.answer(reply) { await VaultBroker.shared.providerStates().map { $0.jsonObject() } } },
    "refresh": { args, reply in
      let id = try VaultsModule.provider(args)
      let anyway = try args.optionalBool("anyway") ?? false
      let download = try args.optionalBool("download") ?? false
      VaultsModule.answer(reply) { await VaultBroker.shared.refresh(id, explicit: true, anyway: anyway, download: download)?.jsonObject() }
    },
    "items": { args, reply in
      let id = try VaultsModule.optionalProvider(args)
      VaultsModule.answer(reply) { await VaultBroker.shared.items(id).map { $0.jsonObject() } }
    },
    "lock": { args, reply in
      let id = try VaultsModule.provider(args)
      VaultsModule.answer(reply) { await VaultBroker.shared.lock(id)?.jsonObject() }
    },
    "signOut": { args, reply in
      let id = try VaultsModule.provider(args)
      VaultsModule.answer(reply) { await VaultBroker.shared.signOut(id)?.jsonObject() }
    },
    "configure": { args, reply in
      let id = try VaultsModule.provider(args)
      let server = try args.optionalText("server")
      VaultsModule.answer(reply) { await VaultBroker.shared.configure(id, server: server)?.jsonObject() }
    },
    "cancelSignIn": { args, reply in
      let id = try VaultsModule.provider(args)
      VaultsModule.answer(reply) { await VaultBroker.shared.cancelSignIn(id)?.jsonObject() }
    },
    "copy": { args, reply in
      let id = try VaultsModule.provider(args)
      let item = try args.text("id")
      let field: VaultField = try args.choice("field")
      VaultsModule.answer(reply) { VaultsModule.copied(await VaultBroker.shared.copy(id, item: item, field: field)) }
    },
    "totp": { args, reply in
      let id = try VaultsModule.provider(args)
      let item = try args.text("id")
      VaultsModule.answer(reply) { await VaultBroker.shared.totp(id, item: item)?.jsonObject() }
    },
    "googleProfiles": { _, reply in reply.ok(GooglePasswordManagerVault.profileList(VaultSessionStore.shared)) },
    "googleAccount": { _, reply in reply.ok(VaultsModule.googleAccount()) },
    "googleSource": { args, reply in
      let choice: GoogleSourceChoice = try args.choice("choice")
      VaultsModule.answer(reply) { await VaultBroker.shared.setGoogleSource(choice)?.jsonObject() }
    },
    "forgetGooglePassword": { _, reply in
      GoogleAccountPassword.forget()
      reply.ok(VaultsModule.googleAccount())
    },
    "googleSignIn": { _, reply in
      VaultsModule.answer(reply) { ["state": await GoogleWebImporter.shared.checkSignIn()] }
    },
    "googleReveal": { args, reply in
      let id = try args.optionalText("id")
      VaultsModule.answer(reply) { ["revealed": await GoogleWebImporter.shared.reveal(id)] }
    },
    "biometrics": { _, reply in reply.ok(["available": VaultOwnerCheck.biometricsAvailable]) },
    "generate": { _, reply in reply.ok(["length": VaultPasswordGenerator.generate().count]) },
    "setOptions": { args, reply in
      let minutes = try args.double("idleLockMinutes")
      let touchID = try args.bool("touchID")
      let askBeforeFilling = try args.optionalBool("askBeforeFilling") ?? true
      let loadPasswordsWhenUsed = try args.optionalBool("loadPasswordsWhenUsed") ?? false
      let syncIntervalSeconds = try args.optionalDouble("syncIntervalSeconds")
      let idle = minutes.isFinite ? Int(min(max(minutes, 0), 10_080)) : 30
      VaultsModule.answer(reply) {
        await VaultBroker.shared.setOptions(idleLockMinutes: idle, touchID: touchID, askBeforeFilling: askBeforeFilling, loadPasswordsWhenUsed: loadPasswordsWhenUsed,
          syncIntervalSeconds: syncIntervalSeconds)
        return [String: Any]()
      }
    },
  ])
}
