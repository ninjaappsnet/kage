import Foundation
import Testing

@testable import SupacodeSettingsShared

struct CLIInstallerTests {
  private let bundleBin = "/Applications/Kage.app/Contents/Resources/bin"

  @Test func managesBothNames() {
    #expect(CLIInstaller.linkNames == ["supacode", "kage"])
  }

  @Test func installCommandLinksEachNameToTheBundle() {
    let command = CLIInstaller.installCommand(bundleBin: bundleBin, installDirectory: "/usr/local/bin")
    #expect(command.hasPrefix("mkdir -p '/usr/local/bin'"))
    #expect(
      command.contains("rm -f '/usr/local/bin/supacode' && ln -s '\(bundleBin)/supacode' '/usr/local/bin/supacode'"))
    #expect(command.contains("rm -f '/usr/local/bin/kage' && ln -s '\(bundleBin)/kage' '/usr/local/bin/kage'"))
  }

  @Test func uninstallCommandRemovesOnlyTheGivenNames() {
    let command = CLIInstaller.uninstallCommand(names: ["kage"], installDirectory: "/usr/local/bin")
    #expect(command == "rm -f '/usr/local/bin/kage'")
  }

  @Test func installedOnlyWhenEveryLinkPointsAtTheBundle() {
    let both = [
      "/usr/local/bin/supacode": "\(bundleBin)/supacode",
      "/usr/local/bin/kage": "\(bundleBin)/kage",
    ]
    #expect(
      CLIInstaller.linkedNames(bundleBin: bundleBin, installDirectory: "/usr/local/bin") { both[$0] } == [
        "supacode", "kage",
      ])
    #expect(CLIInstaller.isInstalled(linkedNames: ["supacode", "kage"]))
    // An install made before the kage alias existed is reported as not installed
    // so the Install button offers to add it.
    #expect(!CLIInstaller.isInstalled(linkedNames: ["supacode"]))
    #expect(!CLIInstaller.isInstalled(linkedNames: []))
  }

  @Test func linksPointingElsewhereAreNotOurs() {
    let other = [
      "/usr/local/bin/supacode": "/opt/other/supacode",
      "/usr/local/bin/kage": "\(bundleBin)/kage",
    ]
    let linked = CLIInstaller.linkedNames(bundleBin: bundleBin, installDirectory: "/usr/local/bin") { other[$0] }
    #expect(linked == ["kage"])
  }

  @Test func quotesEmbeddedSingleQuotes() {
    let command = CLIInstaller.uninstallCommand(names: ["a"], installDirectory: "/it's")
    #expect(command == "rm -f '/it'\\''s/a'")
  }
}
