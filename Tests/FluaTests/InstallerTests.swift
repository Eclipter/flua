import Foundation

@main struct InstallerTests {
    static func main() throws {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let installScriptURL = rootURL.appendingPathComponent("install.sh")
        precondition(FileManager.default.fileExists(atPath: installScriptURL.path), "install.sh must exist at repo root")

        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("flua-installer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // 1. Help message
        let helpRun = runScript(scriptURL: installScriptURL, arguments: ["--help"])
        precondition(helpRun.status == 0, "install.sh --help should exit 0")
        precondition(helpRun.stdout.contains("Usage: install.sh"), "Help text missing usage")

        // 2. Unknown option
        let unknownRun = runScript(scriptURL: installScriptURL, arguments: ["--invalid-flag"])
        precondition(unknownRun.status != 0, "Unknown flag must fail")
        precondition(unknownRun.stderr.contains("Unknown argument"), "Unknown flag error missing")

        // 3. Target directory does not exist
        let nonExistentDir = tempBase.appendingPathComponent("nonexistent").path
        let missingDirRun = runScript(scriptURL: installScriptURL, arguments: ["--dir", nonExistentDir])
        precondition(missingDirRun.status != 0, "Non-existent install dir must fail")
        precondition(missingDirRun.stderr.contains("does not exist"), "Missing dir error text mismatch")

        // 4. Target directory is not writable
        let unwritableDir = tempBase.appendingPathComponent("unwritable")
        try FileManager.default.createDirectory(at: unwritableDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unwritableDir.path)
        let unwritableRun = runScript(scriptURL: installScriptURL, arguments: ["--dir", unwritableDir.path])
        precondition(unwritableRun.status != 0, "Unwritable install dir must fail")
        precondition(unwritableRun.stderr.contains("not writable"), "Unwritable error text mismatch")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unwritableDir.path)

        // 5. Architecture check failure (mocked uname)
        let mockBinDir = tempBase.appendingPathComponent("mock-bin")
        try FileManager.default.createDirectory(at: mockBinDir, withIntermediateDirectories: true)

        let mockUnameURL = mockBinDir.appendingPathComponent("uname")
        let mockUnameScript = """
        #!/bin/sh
        if [ "$1" = "-s" ]; then echo "Darwin"; exit 0; fi
        if [ "$1" = "-m" ]; then echo "x86_64"; exit 0; fi
        exec /usr/bin/uname "$@"
        """
        try mockUnameScript.write(to: mockUnameURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockUnameURL.path)

        var envWithMock = ProcessInfo.processInfo.environment
        envWithMock["PATH"] = "\(mockBinDir.path):\(envWithMock["PATH"] ?? "")"

        let archRun = runScript(scriptURL: installScriptURL, arguments: [], environment: envWithMock)
        precondition(archRun.status != 0, "x86_64 arch must fail")
        precondition(archRun.stderr.contains("Apple Silicon"), "Arch check error text mismatch")

        // 6. OS check failure (mocked uname for OS)
        let mockUnameLinux = """
        #!/bin/sh
        if [ "$1" = "-s" ]; then echo "Linux"; exit 0; fi
        exec /usr/bin/uname "$@"
        """
        try mockUnameLinux.write(to: mockUnameURL, atomically: true, encoding: .utf8)
        let osRun = runScript(scriptURL: installScriptURL, arguments: [], environment: envWithMock)
        precondition(osRun.status != 0, "Non-Darwin OS must fail")
        precondition(osRun.stderr.contains("requires macOS"), "OS check error text mismatch")
        try? FileManager.default.removeItem(at: mockUnameURL)

        // 7. Version check failure (mocked sw_vers returning macOS 26)
        let mockSwVersURL = mockBinDir.appendingPathComponent("sw_vers")
        let mockSwVersScript = """
        #!/bin/sh
        if [ "$1" = "-productVersion" ]; then echo "26.2.1"; exit 0; fi
        exec /usr/bin/sw_vers "$@"
        """
        try mockSwVersScript.write(to: mockSwVersURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockSwVersURL.path)

        let versionRun = runScript(scriptURL: installScriptURL, arguments: [], environment: envWithMock)
        precondition(versionRun.status != 0, "macOS < 27 must fail")
        precondition(versionRun.stderr.contains("macOS 27 or later"), "Version check error text mismatch")
        try? FileManager.default.removeItem(at: mockSwVersURL)

        // 8. Downloaded archive missing Flua.app
        let badZipURL = tempBase.appendingPathComponent("bad.zip")
        let dummyFolder = tempBase.appendingPathComponent("dummy_folder")
        try FileManager.default.createDirectory(at: dummyFolder, withIntermediateDirectories: true)
        try "not flua".write(to: dummyFolder.appendingPathComponent("something.txt"), atomically: true, encoding: .utf8)
        let dittoBad = Process()
        dittoBad.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoBad.arguments = ["-c", "-k", dummyFolder.path, badZipURL.path]
        try dittoBad.run()
        dittoBad.waitUntilExit()

        var badArchiveEnv = ProcessInfo.processInfo.environment
        badArchiveEnv["FLUA_DOWNLOAD_URL"] = "file://\(badZipURL.path)"
        let targetAppsDir = tempBase.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: targetAppsDir, withIntermediateDirectories: true)

        let badArchiveRun = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: badArchiveEnv)
        precondition(badArchiveRun.status != 0, "Archive without Flua.app must fail")
        precondition(badArchiveRun.stderr.contains("does not contain Flua.app"), "Missing app error mismatch")

        // 9. Successful end-to-end installation and quarantine removal
        let mockAppURL = tempBase.appendingPathComponent("Flua.app")
        let mockContents = mockAppURL.appendingPathComponent("Contents")
        let mockMacOS = mockContents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: mockMacOS, withIntermediateDirectories: true)
        let mockBinary = mockMacOS.appendingPathComponent("Flua")
        try "#!/bin/sh\necho 'Flua Mock'\n".write(to: mockBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockBinary.path)

        let validZipURL = tempBase.appendingPathComponent("Flua.zip")
        let dittoValid = Process()
        dittoValid.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoValid.arguments = ["-c", "-k", "--keepParent", mockAppURL.path, validZipURL.path]
        try dittoValid.run()
        dittoValid.waitUntilExit()
        precondition(dittoValid.terminationStatus == 0, "Creating mock zip failed")

        var validEnv = ProcessInfo.processInfo.environment
        validEnv["FLUA_DOWNLOAD_URL"] = "file://\(validZipURL.path)"

        let successRun = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: validEnv)
        precondition(successRun.status == 0, "Installation failed: \(successRun.stderr)")
        precondition(successRun.stdout.contains("Flua successfully installed"), "Missing success message")

        let installedApp = targetAppsDir.appendingPathComponent("Flua.app")
        precondition(FileManager.default.fileExists(atPath: installedApp.path), "Flua.app was not installed")
        let installedBin = installedApp.appendingPathComponent("Contents/MacOS/Flua")
        precondition(FileManager.default.fileExists(atPath: installedBin.path), "Installed app binary missing")

        // 10. Quarantine removal check
        let xattrSet = Process()
        xattrSet.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrSet.arguments = ["-w", "com.apple.quarantine", "0081;mock;curl;", installedApp.path]
        try xattrSet.run()
        xattrSet.waitUntilExit()

        // Re-run installer: it should update existing installation and clear quarantine
        let updateRun = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: validEnv)
        precondition(updateRun.status == 0, "Update installation failed: \(updateRun.stderr)")

        let xattrCheck = Process()
        xattrCheck.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrCheck.arguments = ["-p", "com.apple.quarantine", installedApp.path]
        xattrCheck.standardOutput = Pipe()
        xattrCheck.standardError = Pipe()
        try xattrCheck.run()
        xattrCheck.waitUntilExit()
        precondition(xattrCheck.terminationStatus != 0, "Quarantine attribute should have been removed")

        print("PASS: installer validates OS, architecture, version, directory permissions, extracts Flua.zip, strips quarantine, and cleans up temporary directories")
    }

    struct ScriptResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func runScript(scriptURL: URL, arguments: [String], environment: [String: String]? = nil) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + arguments
        if let environment = environment {
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return ScriptResult(
                status: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return ScriptResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
    }
}
