import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Nonisolated: the quoting tests run real processes, and waiting for them on
/// the main actor lets the test host's SwiftUI re-enter mid-test.
nonisolated struct RemoteKageAttachCommandTests {
  private static let host = RemoteKageHost(name: "Mini", username: "ahmet", address: "mini.tail.ts.net")
  private static let zmxPath = "/Applications/Kage.app/Contents/Resources/zmx/zmx"
  private static let session = "supa-0259f68d-3ac4-42dd-a622-d055383ff36a"

  // MARK: - Host mapping

  @Test func mapsHostToSSHDestinationWithUsername() {
    let remote = RemoteKageAttachCommand.remoteHost(for: Self.host)
    #expect(remote == RemoteHost(alias: "mini.tail.ts.net", username: "ahmet"))
    #expect(remote.sshDestination == "ahmet@mini.tail.ts.net")
  }

  @Test func emptyUsernameMapsToBareAlias() {
    let host = RemoteKageHost(name: "Mini", username: "", address: "10.0.0.4")
    #expect(RemoteKageAttachCommand.remoteHost(for: host) == RemoteHost(alias: "10.0.0.4"))
  }

  // MARK: - Remote script

  @Test func attachScriptGuardsAttachBehindAnExactListMatch() {
    #expect(
      RemoteKageAttachCommand.attachScript
        == #"""
        if "$1" list --short 2>/dev/null | grep -qxF -- "$2"; then
        exec "$1" attach "$2"
        fi
        printf '\033[2m── The remote session is no longer running. ──\033[0m\r\n'
        exit 0
        """#
    )
  }

  // MARK: - Exact command strings

  @Test func attachLineIsTheSharedInteractiveSSHLineWithPositionalArguments() throws {
    let line = try RemoteKageAttachCommand.attachLine(host: Self.host, zmxPath: Self.zmxPath, session: Self.session)
      .get()
    #expect(
      line
        == SSHCommand.commandLine(
          host: RemoteHost(alias: "mini.tail.ts.net", username: "ahmet"),
          remoteScript: RemoteKageAttachCommand.attachScript,
          positionalArguments: ["kage-remote-attach", Self.zmxPath, Self.session]
        )
    )
    // Same multiplexed connection as polling and the rest of the app.
    #expect(
      line.hasPrefix(
        "/usr/bin/ssh -o ControlMaster=auto -o ControlPath=~/.ssh/supacode-%C -o ControlPersist=10m"
      )
    )
    #expect(line.contains(" -tt ahmet@mini.tail.ts.net '"))
  }

  @Test func surfaceCommandIsTheReconnectLoopUnderBinSh() throws {
    let line = try RemoteKageAttachCommand.attachLine(host: Self.host, zmxPath: Self.zmxPath, session: Self.session)
      .get()
    let command = try RemoteKageAttachCommand.surfaceCommand(
      host: Self.host,
      zmxPath: Self.zmxPath,
      session: Self.session
    ).get()
    // Connect and reconnect are the same attach-only line: neither may create.
    #expect(
      command == "/bin/sh -c " + SSHCommand.shellQuote(SSHReconnectLoop.script(connect: line, reconnect: line))
    )
  }

  @Test func customControlPathReachesTheLine() throws {
    let line = try RemoteKageAttachCommand.attachLine(
      host: Self.host,
      zmxPath: Self.zmxPath,
      session: Self.session,
      controlPath: "~/.ssh/test-%C"
    ).get()
    #expect(line.contains("-o ControlPath=~/.ssh/test-%C"))
  }

  // MARK: - Validation

  @Test(arguments: [
    "-oProxyCommand=touch /tmp/x",
    "host;rm -rf ~",
    "host name",
    "$(touch x)",
    "",
    "host\nother",
    "a`b`",
  ])
  func rejectsHostileAddresses(address: String) {
    let host = RemoteKageHost(name: "Bad", username: "ahmet", address: address)
    #expect(
      RemoteKageAttachCommand.attachLine(host: host, zmxPath: Self.zmxPath, session: Self.session)
        == .failure(.invalidDestination)
    )
  }

  @Test(arguments: ["-l", "a b", "a;b", "a@b", "a'b"])
  func rejectsHostileUsernames(username: String) {
    let host = RemoteKageHost(name: "Bad", username: username, address: "mini.local")
    #expect(
      RemoteKageAttachCommand.attachLine(host: host, zmxPath: Self.zmxPath, session: Self.session)
        == .failure(.invalidDestination)
    )
  }

  @Test(arguments: ["mini.local", "10.0.0.4", "fe80::1", "mini-2.tail96d5dd.ts.net", "MINI_1"])
  func acceptsOrdinaryAddresses(address: String) {
    let host = RemoteKageHost(name: "Ok", username: "ahmet.cetin", address: address)
    let line = try? RemoteKageAttachCommand.attachLine(host: host, zmxPath: Self.zmxPath, session: Self.session).get()
    #expect(line != nil)
  }

  @Test func rejectsARelativeZmxPath() {
    // Bare "zmx" would resolve against the host's PATH, which may not have it
    // (or may have a different build).
    #expect(
      RemoteKageAttachCommand.attachLine(host: Self.host, zmxPath: "zmx", session: Self.session)
        == .failure(.zmxPathNotAbsolute)
    )
  }

  @Test(arguments: ["", "-force", "--force", "a\nb", "a\u{7}b"])
  func rejectsUnsafeSessionNames(session: String) {
    #expect(
      RemoteKageAttachCommand.attachLine(host: Self.host, zmxPath: Self.zmxPath, session: session)
        == .failure(.invalidSession)
    )
  }

  // MARK: - Behaviour through every quoting layer

  /// Runs the attach line's remote command locally exactly as sshd would hand it
  /// to the login shell, with a fake zmx that records its arguments.
  @Test func attachesAnExistingSessionThroughEveryQuotingLayer() throws {
    let sandbox = try FakeZmx(listing: [Self.session, "supa-other"])
    defer { sandbox.remove() }
    let run = try sandbox.runRemoteCommand(host: Self.host, session: Self.session)
    #expect(run.status == 0)
    #expect(sandbox.invocations() == [["list", "--short"], ["attach", Self.session]])
  }

  @Test func zmxPathWithSpacesAndQuotesSurvivesTheQuoting() throws {
    let sandbox = try FakeZmx(listing: [Self.session], directoryName: "Kage it's $(touch pwned) `touch pwned`")
    defer { sandbox.remove() }
    let run = try sandbox.runRemoteCommand(host: Self.host, session: Self.session)
    #expect(run.status == 0)
    #expect(sandbox.invocations() == [["list", "--short"], ["attach", Self.session]])
    #expect(!sandbox.pwnedMarkerExists)
  }

  @Test func hostileSessionNameIsPassedAsOneLiteralArgument() throws {
    let hostile = #"x'; touch pwned; '$(touch pwned)"\`touch pwned\` \\ "#
    let sandbox = try FakeZmx(listing: [hostile])
    defer { sandbox.remove() }
    let run = try sandbox.runRemoteCommand(host: Self.host, session: hostile)
    #expect(run.status == 0)
    #expect(sandbox.invocations() == [["list", "--short"], ["attach", hostile]])
    #expect(!sandbox.pwnedMarkerExists)
  }

  @Test func attachesAListedSessionEvenWhenListingExitsNonZero() throws {
    // zmx list can exit non-zero over another session's stale socket; the
    // name it printed is still live.
    let sandbox = try FakeZmx(listing: [Self.session], listExitStatus: 1)
    defer { sandbox.remove() }
    let run = try sandbox.runRemoteCommand(host: Self.host, session: Self.session)
    #expect(run.status == 0)
    #expect(sandbox.invocations() == [["list", "--short"], ["attach", Self.session]])
  }

  @Test func neverAttachesWhenTheSessionIsGone() throws {
    // Substring and prefix neighbours must not count as a match: zmx attach
    // would create a fresh session under the missing name.
    let sandbox = try FakeZmx(listing: [Self.session + "-2", "x" + Self.session, "supa-other"])
    defer { sandbox.remove() }
    let run = try sandbox.runRemoteCommand(host: Self.host, session: Self.session)
    #expect(run.status == 0)
    #expect(sandbox.invocations() == [["list", "--short"]])
    #expect(run.output.contains("The remote session is no longer running."))
  }

  @Test func neverAttachesWhenListingFailsWithoutOutput() throws {
    // e.g. no socket dir yet, or zmx missing at that path.
    let sandbox = try FakeZmx(listing: [], listExitStatus: 1)
    defer { sandbox.remove() }
    let run = try sandbox.runRemoteCommand(host: Self.host, session: Self.session)
    #expect(run.status == 0)
    #expect(sandbox.invocations() == [["list", "--short"]])
  }
}

/// A temporary directory holding a fake zmx script. The fake prints the given
/// listing for "list --short" and records every invocation's arguments, one
/// record per log line, arguments separated by the unit separator.
private nonisolated struct FakeZmx {
  let root: URL
  let zmxPath: String
  let logPath: String

  init(listing: [String], listExitStatus: Int = 0, directoryName: String = "bin") throws {
    root = FileManager.default.temporaryDirectory.appending(path: "kage-attach-\(UUID().uuidString)")
    let directory = root.appending(path: directoryName)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let zmx = directory.appending(path: "zmx")
    zmxPath = zmx.path(percentEncoded: false)
    logPath = root.appending(path: "invocations.log").path(percentEncoded: false)
    let listingPath = root.appending(path: "listing.txt")
    try (listing.joined(separator: "\n") + "\n").write(to: listingPath, atomically: true, encoding: .utf8)
    let script = """
      #!/bin/sh
      for arg in "$@"; do printf '%s\\037' "$arg"; done >> \(SSHCommand.shellQuote(logPath))
      printf '\\n' >> \(SSHCommand.shellQuote(logPath))
      if [ "$1" = list ]; then
        cat \(SSHCommand.shellQuote(listingPath.path(percentEncoded: false)))
        exit \(listExitStatus)
      fi
      exit 0
      """
    try script.write(to: zmx, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmxPath)
  }

  var pwnedMarkerExists: Bool {
    FileManager.default.fileExists(atPath: root.appending(path: "pwned").path(percentEncoded: false))
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  func invocations() -> [[String]] {
    guard let log = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
    return log.split(separator: "\n").map { line in
      line.split(separator: "\u{1F}", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
  }

  /// Splits the local ssh line into argv with /bin/sh (the parser Ghostty's
  /// command goes through), takes the remote command (the last argument), and
  /// runs it the way sshd does: "$SHELL" -c <command>.
  func runRemoteCommand(host: RemoteKageHost, session: String) throws -> (status: Int32, output: String) {
    let line = try RemoteKageAttachCommand.attachLine(host: host, zmxPath: zmxPath, session: session).get()
    let words = String(line.dropFirst(SSHCommand.sshExecutablePath.count))
    let argv = try Self.run(["/bin/sh", "-c", #"printf '%s\0' "# + words], in: root).output
      .split(separator: "\0", omittingEmptySubsequences: false)
      .dropLast()
    let remoteCommand = try #require(argv.last.map(String.init))
    return try Self.run(["/bin/sh", "-c", remoteCommand], in: root)
  }

  private static func run(_ arguments: [String], in directory: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    process.currentDirectoryURL = directory
    // A plain POSIX login shell keeps the user's profile out of the test.
    process.environment = [
      "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "TERM": "dumb", "HOME": directory.path(percentEncoded: false),
    ]
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
  }
}
