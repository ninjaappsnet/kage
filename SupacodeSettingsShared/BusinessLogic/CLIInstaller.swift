import Foundation

nonisolated struct CLIInstaller {
  static let installDirectory = "/usr/local/bin"
  /// The CLI's names: `supacode` stays for upstream script/hook compatibility,
  /// `kage` is the fork's own. The bundle ships both under `Resources/bin`.
  static let linkNames = ["supacode", "kage"]

  /// Returns the directory holding the CLI binaries inside the app bundle.
  static var bundledBinDirectory: String? {
    Bundle.main.resourceURL?
      .appending(path: "bin", directoryHint: .isDirectory)
      .path(percentEncoded: false)
  }

  /// Returns the path to the CLI binary inside the app bundle.
  static var bundledCLIPath: String? {
    bundledBinDirectory.map { "\($0)/supacode" }
  }

  /// The names whose link in `installDirectory` points at this bundle.
  /// `resolve` reads a symlink's destination (injected for tests).
  static func linkedNames(
    bundleBin: String,
    installDirectory: String,
    resolve: (String) -> String?
  ) -> [String] {
    linkNames.filter { resolve("\(installDirectory)/\($0)") == "\(bundleBin)/\($0)" }
  }

  /// Installed means every name is linked: an install that predates the `kage`
  /// alias reports false so the Install button offers to add it.
  static func isInstalled(linkedNames: [String]) -> Bool {
    Set(linkedNames) == Set(linkNames)
  }

  static func installCommand(bundleBin: String, installDirectory: String) -> String {
    let links = linkNames.map { name in
      let destination = shellEscape("\(installDirectory)/\(name)")
      return "rm -f \(destination) && ln -s \(shellEscape("\(bundleBin)/\(name)")) \(destination)"
    }
    return (["mkdir -p \(shellEscape(installDirectory))"] + links).joined(separator: " && ")
  }

  static func uninstallCommand(names: [String], installDirectory: String) -> String {
    "rm -f " + names.map { shellEscape("\(installDirectory)/\($0)") }.joined(separator: " ")
  }

  private func linkedNames() -> [String] {
    guard let bundleBin = Self.bundledBinDirectory else { return [] }
    return Self.linkedNames(bundleBin: bundleBin, installDirectory: Self.installDirectory) {
      try? FileManager.default.destinationOfSymbolicLink(atPath: $0)
    }
  }

  func isInstalled() -> Bool {
    Self.isInstalled(linkedNames: linkedNames())
  }

  func install() throws {
    guard let bundleBin = Self.bundledBinDirectory else {
      throw CLIInstallerError.bundledBinaryNotFound
    }
    guard Self.linkNames.allSatisfy({ FileManager.default.fileExists(atPath: "\(bundleBin)/\($0)") }) else {
      throw CLIInstallerError.bundledBinaryNotFound
    }

    // Use NSAppleScript to create the symlinks with admin privileges.
    try runPrivileged(
      Self.installCommand(bundleBin: bundleBin, installDirectory: Self.installDirectory),
      prompt: "Kage needs administrator access to install the CLI to /usr/local/bin."
    )
  }

  func uninstall() throws {
    let names = linkedNames()
    guard !names.isEmpty else { return }
    try runPrivileged(
      Self.uninstallCommand(names: names, installDirectory: Self.installDirectory),
      prompt: "Kage needs administrator access to uninstall the CLI from /usr/local/bin."
    )
  }

  /// Runs a shell command with administrator privileges via `NSAppleScript`.
  ///
  /// Using `NSAppleScript` in-process (instead of shelling out to `/usr/bin/osascript`)
  /// makes macOS show the Kage icon and name in the authorization dialog.
  private func runPrivileged(_ command: String, prompt: String) throws {
    let escapedCommand = command.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
    let escapedPrompt = prompt.replacing("\"", with: "\\\"")
    let source =
      "do shell script \"\(escapedCommand)\" with prompt \"\(escapedPrompt)\" with administrator privileges"
    guard let script = NSAppleScript(source: source) else {
      throw CLIInstallerError.installFailed("Failed to prepare authorization script.")
    }
    var errorInfo: NSDictionary?
    script.executeAndReturnError(&errorInfo)
    guard errorInfo == nil else {
      let errorNumber = errorInfo?[NSAppleScript.errorNumber] as? Int
      // -128 means the user cancelled the authorization dialog.
      if errorNumber == -128 {
        throw CLIInstallerError.cancelled
      }
      let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? ""
      throw CLIInstallerError.installFailed(message)
    }
  }
}

/// Wraps a value in single quotes, escaping embedded single quotes.
private nonisolated func shellEscape(_ value: String) -> String {
  "'" + value.replacing("'", with: "'\\''") + "'"
}

public nonisolated enum CLIInstallerError: Error, LocalizedError, Equatable {
  case bundledBinaryNotFound
  case cancelled
  case installFailed(String)

  public var errorDescription: String? {
    switch self {
    case .bundledBinaryNotFound:
      "The CLI binary was not found in the app bundle."
    case .cancelled:
      nil
    case .installFailed(let reason):
      reason.isEmpty ? "Installation failed." : reason
    }
  }
}
