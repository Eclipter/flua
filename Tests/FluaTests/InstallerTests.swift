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
        let targetAppsDir = tempBase.appendingPathComponent("Test Applications")
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
        let mockInfo = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>Flua</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleIdentifier</key><string>local.flua.desktop</string>
        <key>CFBundleShortVersionString</key><string>0.1.0</string>
        <key>CFBundleVersion</key><string>1</string>
        </dict></plist>
        """
        try mockInfo.write(to: mockContents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        let validZipURL = tempBase.appendingPathComponent("Flua.zip")
        let dittoValid = Process()
        dittoValid.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoValid.arguments = ["-c", "-k", "--keepParent", mockAppURL.path, validZipURL.path]
        try dittoValid.run()
        dittoValid.waitUntilExit()
        precondition(dittoValid.terminationStatus == 0, "Creating mock zip failed")

        var validEnv = ProcessInfo.processInfo.environment
        validEnv["FLUA_DOWNLOAD_URL"] = "file://\(validZipURL.path)"
        validEnv["PATH"] = "\(mockBinDir.path):\(validEnv["PATH"] ?? "")"
        let mockPgrep = mockBinDir.appendingPathComponent("pgrep")
        try "#!/bin/sh\nexit 1\n".write(to: mockPgrep, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockPgrep.path)
        let mockKillall = mockBinDir.appendingPathComponent("killall")
        try "#!/bin/sh\necho 'Unexpected killall call' >&2\nexit 1\n".write(to: mockKillall, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockKillall.path)
        let mockCodesign = mockBinDir.appendingPathComponent("codesign")
        try "#!/bin/sh\nexit \"${FLUA_TEST_CODESIGN_STATUS:-0}\"\n".write(to: mockCodesign, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockCodesign.path)

        let successRun = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: validEnv)
        precondition(successRun.status == 0, "Installation failed: \(successRun.stderr)")
        precondition(successRun.stdout.contains("Flua successfully installed"), "Missing success message")

        let installedApp = targetAppsDir.appendingPathComponent("Flua.app")
        precondition(FileManager.default.fileExists(atPath: installedApp.path), "Flua.app was not installed")
        let installedBin = installedApp.appendingPathComponent("Contents/MacOS/Flua")
        precondition(FileManager.default.fileExists(atPath: installedBin.path), "Installed app binary missing")

        let oldMarker = installedApp.appendingPathComponent("previous-version.txt")
        try "previous installation".write(to: oldMarker, atomically: true, encoding: .utf8)
        let originalBinary = try Data(contentsOf: installedBin)

        // An invalid signature must be rejected before the installed app is moved aside.
        var invalidSignatureEnv = validEnv
        invalidSignatureEnv["FLUA_TEST_CODESIGN_STATUS"] = "1"
        let invalidSignature = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: invalidSignatureEnv)
        precondition(invalidSignature.status != 0, "Invalid app signature must fail")
        precondition(invalidSignature.stderr.contains("invalid signature"), "Invalid signature error missing")
        precondition((try? Data(contentsOf: installedBin)) == originalBinary, "Invalid signature changed the installed binary")
        precondition(FileManager.default.fileExists(atPath: oldMarker.path), "Invalid signature removed the previous installation")

        // Invalid app metadata must also preserve the installed app.
        let malformedInfo = mockContents.appendingPathComponent("Info.plist")
        try "not a plist".write(to: malformedInfo, atomically: true, encoding: .utf8)
        let malformedZip = tempBase.appendingPathComponent("Malformed.zip")
        let malformedArchive = Process()
        malformedArchive.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        malformedArchive.arguments = ["-c", "-k", "--keepParent", mockAppURL.path, malformedZip.path]
        try malformedArchive.run()
        malformedArchive.waitUntilExit()
        precondition(malformedArchive.terminationStatus == 0, "Creating malformed app zip failed")
        var invalidMetadataEnv = validEnv
        invalidMetadataEnv["FLUA_DOWNLOAD_URL"] = "file://\(malformedZip.path)"
        let invalidMetadata = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: invalidMetadataEnv)
        precondition(invalidMetadata.status != 0, "Invalid app metadata must fail")
        precondition(invalidMetadata.stderr.contains("invalid bundle metadata"), "Invalid metadata error missing")
        precondition((try? Data(contentsOf: installedBin)) == originalBinary, "Invalid metadata changed the installed binary")
        precondition(FileManager.default.fileExists(atPath: oldMarker.path), "Invalid metadata removed the previous installation")
        try mockInfo.write(to: malformedInfo, atomically: true, encoding: .utf8)

        // A different app's valid bundle identifier must not replace Flua.
        try mockInfo.replacingOccurrences(of: "local.flua.desktop", with: "example.other.app").write(to: malformedInfo, atomically: true, encoding: .utf8)
        let wrongIdentifierZip = tempBase.appendingPathComponent("WrongIdentifier.zip")
        let wrongIdentifierArchive = Process()
        wrongIdentifierArchive.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        wrongIdentifierArchive.arguments = ["-c", "-k", "--keepParent", mockAppURL.path, wrongIdentifierZip.path]
        try wrongIdentifierArchive.run()
        wrongIdentifierArchive.waitUntilExit()
        precondition(wrongIdentifierArchive.terminationStatus == 0, "Creating wrong-identifier app zip failed")
        var wrongIdentifierEnv = validEnv
        wrongIdentifierEnv["FLUA_DOWNLOAD_URL"] = "file://\(wrongIdentifierZip.path)"
        let wrongIdentifier = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: wrongIdentifierEnv)
        precondition(wrongIdentifier.status != 0, "Wrong app bundle identifier must fail")
        precondition(wrongIdentifier.stderr.contains("invalid bundle metadata"), "Wrong identifier error missing")
        precondition((try? Data(contentsOf: installedBin)) == originalBinary, "Wrong identifier changed the installed binary")
        precondition(FileManager.default.fileExists(atPath: oldMarker.path), "Wrong identifier removed the previous installation")
        try mockInfo.write(to: malformedInfo, atomically: true, encoding: .utf8)

        // A missing app executable must not replace the installed app.
        let mockBinaryContents = try Data(contentsOf: mockBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mockBinary.path)
        let nonExecutableZip = tempBase.appendingPathComponent("NonExecutable.zip")
        let nonExecutableArchive = Process()
        nonExecutableArchive.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        nonExecutableArchive.arguments = ["-c", "-k", "--keepParent", mockAppURL.path, nonExecutableZip.path]
        try nonExecutableArchive.run()
        nonExecutableArchive.waitUntilExit()
        precondition(nonExecutableArchive.terminationStatus == 0, "Creating non-executable app zip failed")
        var nonExecutableEnv = validEnv
        nonExecutableEnv["FLUA_DOWNLOAD_URL"] = "file://\(nonExecutableZip.path)"
        let nonExecutable = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: nonExecutableEnv)
        precondition(nonExecutable.status != 0, "Non-executable app binary must fail")
        precondition(nonExecutable.stderr.contains("no executable Flua app binary"), "Non-executable error missing")
        precondition((try? Data(contentsOf: installedBin)) == originalBinary, "Non-executable app changed the installed binary")
        precondition(FileManager.default.fileExists(atPath: oldMarker.path), "Non-executable app removed the previous installation")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockBinary.path)
        try FileManager.default.removeItem(at: mockBinary)
        let missingExecutableZip = tempBase.appendingPathComponent("MissingExecutable.zip")
        let missingExecutableArchive = Process()
        missingExecutableArchive.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        missingExecutableArchive.arguments = ["-c", "-k", "--keepParent", mockAppURL.path, missingExecutableZip.path]
        try missingExecutableArchive.run()
        missingExecutableArchive.waitUntilExit()
        precondition(missingExecutableArchive.terminationStatus == 0, "Creating app without an executable zip failed")
        var missingExecutableEnv = validEnv
        missingExecutableEnv["FLUA_DOWNLOAD_URL"] = "file://\(missingExecutableZip.path)"
        let missingExecutable = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: missingExecutableEnv)
        precondition(missingExecutable.status != 0, "Missing app executable must fail")
        precondition(missingExecutable.stderr.contains("no executable Flua app binary"), "Missing executable error missing")
        precondition((try? Data(contentsOf: installedBin)) == originalBinary, "Missing executable changed the installed binary")
        precondition(FileManager.default.fileExists(atPath: oldMarker.path), "Missing executable removed the previous installation")
        try mockBinaryContents.write(to: mockBinary)

        // A partial copy must leave the installed app intact and remove staging files.
        let mockCopy = mockBinDir.appendingPathComponent("cp")
        try "#!/bin/sh\n/bin/cp \"$@\"\nexit 37\n".write(to: mockCopy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockCopy.path)
        let copyFailure = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: validEnv)
        precondition(copyFailure.status == 37, "Injected copy failure must reach the caller")
        precondition((try? Data(contentsOf: installedBin)) == originalBinary, "Copy failure changed the installed binary")
        precondition(FileManager.default.fileExists(atPath: oldMarker.path), "Copy failure removed the previous installation")
        precondition((try? FileManager.default.contentsOfDirectory(atPath: targetAppsDir.path)) == ["Flua.app"], "Copy failure left staging files behind")
        try FileManager.default.removeItem(at: mockCopy)

        // A failed final rename must restore the app moved aside for replacement.
        let mockMove = mockBinDir.appendingPathComponent("mv")
        let moveScript = """
        #!/bin/sh
        if [ "$1" != "$FLUA_TEST_TARGET" ] && [ "$2" = "$FLUA_TEST_TARGET" ] && [ "${1##*/}" = "Flua.app" ]; then
            exit 38
        fi
        exec /bin/mv "$@"
        """
        try moveScript.write(to: mockMove, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockMove.path)
        validEnv["FLUA_TEST_TARGET"] = installedApp.path
        let moveFailure = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: validEnv)
        precondition(moveFailure.status == 38, "Injected replacement failure must reach the caller")
        precondition((try? Data(contentsOf: installedBin)) == originalBinary, "Replacement failure changed the installed binary")
        precondition(FileManager.default.fileExists(atPath: oldMarker.path), "Replacement failure removed the previous installation")
        precondition((try? FileManager.default.contentsOfDirectory(atPath: targetAppsDir.path)) == ["Flua.app"], "Replacement failure left staging files behind")
        try FileManager.default.removeItem(at: mockMove)

        // 10. Quarantine removal check
        let xattrSet = Process()
        xattrSet.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrSet.arguments = ["-w", "com.apple.quarantine", "0081;mock;curl;", installedApp.path]
        try xattrSet.run()
        xattrSet.waitUntilExit()

        // Re-run installer: it should update existing installation and clear quarantine
        let updateRun = runScript(scriptURL: installScriptURL, arguments: ["--dir", targetAppsDir.path], environment: validEnv)
        precondition(updateRun.status == 0, "Update installation failed: \(updateRun.stderr)")
        precondition(!FileManager.default.fileExists(atPath: oldMarker.path), "Successful update retained files from the previous installation")
        precondition((try? FileManager.default.contentsOfDirectory(atPath: targetAppsDir.path)) == ["Flua.app"], "Successful update left staging files behind")

        let xattrCheck = Process()
        xattrCheck.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrCheck.arguments = ["-p", "com.apple.quarantine", installedApp.path]
        xattrCheck.standardOutput = Pipe()
        xattrCheck.standardError = Pipe()
        try xattrCheck.run()
        xattrCheck.waitUntilExit()
        precondition(xattrCheck.terminationStatus != 0, "Quarantine attribute should have been removed")

        print("PASS: installer validates prerequisites and downloaded apps, preserves the installed app after validation or replacement failure, strips quarantine, and cleans up staging directories")
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
