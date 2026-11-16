// pi-vault-keychain: the macOS backend of pi-vault.
//
// Secrets live in the login keychain as generic passwords (service "pi-vault",
// account = secret name), the same place Keychain Access shows them.
//
// What makes this more than a wrapper around `security`:
//   - Items are created BY THIS BINARY, so their access list trusts only this
//     binary (by code signature). Any other process that reads one,
//     including `security find-generic-password -w`, gets the macOS keychain
//     dialog asking for the login password. An agent cannot answer that.
//   - `get` asks for Touch ID (or the login password as a fallback) before it
//     reads anything. So running this binary directly does not help an agent
//     either: it can trigger the prompt, but it cannot satisfy it.
//   - If the binary is modified or rebuilt, its signature changes and the
//     keychain stops trusting it: the next read shows the keychain dialog
//     again. Only click "Always Allow" if you rebuilt it yourself.
//
// Usage:
//   pi-vault-keychain set NAME        value from stdin (hidden prompt on a tty)
//   pi-vault-keychain get NAME [WHY]  Touch ID, then the value on stdout
//   pi-vault-keychain delete NAME
//   pi-vault-keychain list            names only, never values
//
// Exit codes: 0 ok, 1 usage/other, 2 not found, 3 authentication denied.

import Foundation
import LocalAuthentication
import Security

let service = "pi-vault"

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
  FileHandle.standardError.write(("pi-vault-keychain: " + msg + "\n").data(using: .utf8)!)
  exit(code)
}

func validName(_ s: String) -> Bool {
  !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isLetter || $0.isNumber || "_-.".contains($0) }
}

func baseQuery(_ name: String) -> [String: Any] {
  [kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: service,
   kSecAttrAccount as String: name]
}

func errorText(_ status: OSStatus) -> String {
  (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
}

/// Touch ID, falling back to the login password. Blocks until answered.
func authenticate(_ reason: String) -> Bool {
  let ctx = LAContext()
  var err: NSError?
  guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
    fail("cannot ask for authentication: \(err?.localizedDescription ?? "unknown")", 3)
  }
  let done = DispatchSemaphore(value: 0)
  var ok = false
  ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
    ok = success
    done.signal()
  }
  done.wait()
  return ok
}

func readValue() -> String {
  if isatty(STDIN_FILENO) != 0 {
    var buf = [CChar](repeating: 0, count: 8192)
    guard let p = readpassphrase("Secret value (hidden): ", &buf, buf.count, 0) else {
      fail("could not read the value")
    }
    let v = String(cString: p)
    buf.withUnsafeMutableBufferPointer { b in for i in b.indices { b[i] = 0 } }
    return v
  }
  let data = FileHandle.standardInput.readDataToEndOfFile()
  var v = String(decoding: data, as: UTF8.self)
  if v.hasSuffix("\n") { v.removeLast() }
  return v
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
  fail("usage: pi-vault-keychain set|get|delete NAME | list")
}

switch cmd {
case "set":
  guard args.count == 2, validName(args[1]) else { fail("usage: set NAME (letters, digits, _ - .)") }
  let name = args[1]
  let value = readValue()
  if value.isEmpty { fail("empty value, nothing stored") }
  // Replace, never update in place: a fresh item gets a fresh access list
  // that trusts only this binary, whoever created the old one.
  SecItemDelete(baseQuery(name) as CFDictionary)
  var add = baseQuery(name)
  add[kSecAttrLabel as String] = "pi-vault: \(name)"
  add[kSecValueData as String] = value.data(using: .utf8)!
  let st = SecItemAdd(add as CFDictionary, nil)
  guard st == errSecSuccess else { fail("could not store \(name): \(errorText(st))") }
  print("stored \(name) in the login keychain (service \(service))")

case "get":
  guard args.count >= 2, validName(args[1]) else { fail("usage: get NAME [REASON]") }
  let name = args[1]
  // Check existence first (attributes only, no prompt), so a missing name
  // does not cost a fingerprint.
  var probe = baseQuery(name)
  probe[kSecReturnAttributes as String] = true
  let ps = SecItemCopyMatching(probe as CFDictionary, nil)
  if ps == errSecItemNotFound { fail("no secret named \(name)", 2) }
  let why = args.count > 2 ? args[2...].joined(separator: " ") : "an agent asked for it"
  guard authenticate("release the secret \"\(name)\" to pi: \(why)") else {
    fail("authentication denied", 3)
  }
  var q = baseQuery(name)
  q[kSecReturnData as String] = true
  q[kSecMatchLimit as String] = kSecMatchLimitOne
  var out: CFTypeRef?
  let st = SecItemCopyMatching(q as CFDictionary, &out)
  if st == errSecItemNotFound { fail("no secret named \(name)", 2) }
  if st == errSecAuthFailed || st == errSecUserCanceled { fail("keychain access denied", 3) }
  guard st == errSecSuccess, let data = out as? Data else { fail("could not read \(name): \(errorText(st))") }
  FileHandle.standardOutput.write(data)

case "delete":
  guard args.count == 2, validName(args[1]) else { fail("usage: delete NAME") }
  let st = SecItemDelete(baseQuery(args[1]) as CFDictionary)
  if st == errSecItemNotFound { fail("no secret named \(args[1])", 2) }
  guard st == errSecSuccess else { fail("could not delete: \(errorText(st))") }
  print("deleted \(args[1])")

case "list":
  let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                          kSecAttrService as String: service,
                          kSecReturnAttributes as String: true,
                          kSecMatchLimit as String: kSecMatchLimitAll]
  var out: CFTypeRef?
  let st = SecItemCopyMatching(q as CFDictionary, &out)
  if st == errSecItemNotFound { exit(0) }
  guard st == errSecSuccess, let items = out as? [[String: Any]] else { fail("could not list: \(errorText(st))") }
  let names = Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
  for n in names.sorted() { print(n) }

default:
  fail("unknown command \(cmd)")
}
