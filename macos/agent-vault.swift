// agent-vault: the macOS backend. Build with macos/build.sh.
//
// Secrets live in the login keychain as generic passwords (service
// "agent-vault", account = secret name, label "agent-vault: NAME"), the same
// place Keychain Access shows them. Items stored under the old service name
// "pi-vault" are still read as a fallback until `agent-vault migrate` has
// copied them over.
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
//     again. Only click "Allow" if you rebuilt it yourself.
//
// Usage:
//   agent-vault set NAME          value from stdin (hidden prompt on a tty)
//   agent-vault get NAME [WHY]    Touch ID, then the value on stdout
//   agent-vault delete NAME
//   agent-vault list              names only, never values
//   agent-vault migrate [NAME..]  copy legacy "pi-vault" items to "agent-vault"
//
// Exit codes: 0 ok, 1 usage/other, 2 not found, 3 authentication denied.

import Foundation
import LocalAuthentication
import Security

let service = "agent-vault"
let legacyService = "pi-vault"

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
  FileHandle.standardError.write(("agent-vault: " + msg + "\n").data(using: .utf8)!)
  exit(code)
}

func note(_ msg: String) {
  FileHandle.standardError.write(("agent-vault: " + msg + "\n").data(using: .utf8)!)
}

func validName(_ s: String) -> Bool {
  !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isLetter || $0.isNumber || "_-.".contains($0) }
}

func baseQuery(_ name: String, _ svc: String = service) -> [String: Any] {
  [kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: svc,
   kSecAttrAccount as String: name]
}

func errorText(_ status: OSStatus) -> String {
  (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
}

/// True if an item exists. Attributes only, so it never prompts.
func exists(_ name: String, _ svc: String) -> Bool {
  var probe = baseQuery(name, svc)
  probe[kSecReturnAttributes as String] = true
  return SecItemCopyMatching(probe as CFDictionary, nil) != errSecItemNotFound
}

/// Names stored under one service. Attributes only, never values.
func names(_ svc: String) -> Set<String> {
  let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                          kSecAttrService as String: svc,
                          kSecReturnAttributes as String: true,
                          kSecMatchLimit as String: kSecMatchLimitAll]
  var out: CFTypeRef?
  let st = SecItemCopyMatching(q as CFDictionary, &out)
  if st == errSecItemNotFound { return [] }
  guard st == errSecSuccess, let items = out as? [[String: Any]] else { fail("could not list \(svc): \(errorText(st))") }
  return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
}

/// Reads one value. Call only after authenticate().
func read(_ name: String, _ svc: String) -> Data {
  var q = baseQuery(name, svc)
  q[kSecReturnData as String] = true
  q[kSecMatchLimit as String] = kSecMatchLimitOne
  var out: CFTypeRef?
  let st = SecItemCopyMatching(q as CFDictionary, &out)
  if st == errSecItemNotFound { fail("no secret named \(name)", 2) }
  if st == errSecAuthFailed || st == errSecUserCanceled { fail("keychain access denied", 3) }
  guard st == errSecSuccess, let data = out as? Data else { fail("could not read \(name): \(errorText(st))") }
  return data
}

/// Stores a value under the agent-vault service. Replace, never update in
/// place: a fresh item gets a fresh access list that trusts only this binary.
func store(_ name: String, _ data: Data) {
  SecItemDelete(baseQuery(name) as CFDictionary)
  var add = baseQuery(name)
  add[kSecAttrLabel as String] = "agent-vault: \(name)"
  add[kSecValueData as String] = data
  let st = SecItemAdd(add as CFDictionary, nil)
  guard st == errSecSuccess else { fail("could not store \(name): \(errorText(st))") }
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

let usage = "usage: agent-vault set|get|delete NAME | list | migrate [NAME...]"
let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail(usage) }

switch cmd {
case "set":
  guard args.count == 2, validName(args[1]) else { fail("usage: set NAME (letters, digits, _ - .)") }
  let value = readValue()
  if value.isEmpty { fail("empty value, nothing stored") }
  store(args[1], value.data(using: .utf8)!)
  print("stored \(args[1]) in the login keychain (service \(service))")

case "get":
  guard args.count >= 2, validName(args[1]) else { fail("usage: get NAME [REASON]") }
  let name = args[1]
  // Check existence first (attributes only, no prompt), so a missing name
  // does not cost a fingerprint. The new service wins over the legacy one.
  let svc: String
  if exists(name, service) { svc = service }
  else if exists(name, legacyService) { svc = legacyService }
  else { fail("no secret named \(name)", 2) }
  let why = args.count > 2 ? args[2...].joined(separator: " ") : "an agent asked for it"
  guard authenticate("release the secret \"\(name)\" to an agent: \(why)") else {
    fail("authentication denied", 3)
  }
  FileHandle.standardOutput.write(read(name, svc))

case "delete":
  guard args.count == 2, validName(args[1]) else { fail("usage: delete NAME") }
  var deleted = false
  for svc in [service, legacyService] {
    let st = SecItemDelete(baseQuery(args[1], svc) as CFDictionary)
    if st == errSecSuccess { deleted = true; continue }
    if st != errSecItemNotFound { fail("could not delete from \(svc): \(errorText(st))") }
  }
  if !deleted { fail("no secret named \(args[1])", 2) }
  print("deleted \(args[1])")

case "list":
  let current = names(service)
  let legacy = names(legacyService)
  for n in current.union(legacy).sorted() { print(n) }
  let pending = legacy.subtracting(current).count
  if pending > 0 {
    note("\(pending) of these are still under the legacy service \"\(legacyService)\"; `agent-vault migrate` copies them over")
  }

case "migrate":
  let legacy = names(legacyService)
  let wanted = args.count > 1 ? Set(args.dropFirst()) : legacy
  for n in wanted where !legacy.contains(n) { note("\(n): not under \(legacyService), skipped") }
  let todo = wanted.intersection(legacy).sorted()
  if todo.isEmpty { print("nothing to migrate"); exit(0) }
  // One Touch ID for the whole batch. macOS may additionally show its own
  // keychain dialog per item, because the legacy items trust only the old
  // pi-vault-keychain binary: enter the login password and click "Allow".
  guard authenticate("copy \(todo.count) secrets from \(legacyService) to \(service) in the login keychain") else {
    fail("authentication denied", 3)
  }
  var failed = 0
  for n in todo {
    let old = read(n, legacyService)
    if exists(n, service) {
      if read(n, service) != old {
        note("\(n): already under \(service) with a different value, left both alone")
        failed += 1
        continue
      }
    } else {
      store(n, old)
    }
    guard read(n, service) == old else {
      note("\(n): copy does not match, legacy item kept")
      failed += 1
      continue
    }
    let st = SecItemDelete(baseQuery(n, legacyService) as CFDictionary)
    if st == errSecSuccess || st == errSecItemNotFound {
      print("migrated \(n)")
    } else {
      note("\(n): copied and verified, but the legacy item could not be deleted: \(errorText(st))")
    }
  }
  exit(failed == 0 ? 0 : 1)

default:
  fail("unknown command \(cmd)\n\(usage)")
}
