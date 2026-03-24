import Foundation

enum Build {
    static func performCommand(_ options: ArgumentOptions) throws {
        if Utility.shell("which brew") == nil {
            print("""
            You need to run the script first
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            """)
            return
        }
        if Utility.shell("which pkg-config") == nil {
            Utility.shell("brew install pkg-config")
        }
        if Utility.shell("which wget") == nil {
            Utility.shell("brew install wget")
        }
        let path = URL.currentDirectory + "dist"
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: nil)
        }
        try? Utility.removeFiles(extensions: [".swift"], currentDirectoryURL: URL.currentDirectory + ["dist", "release"])
        FileManager.default.changeCurrentDirectoryPath(path.path)
        BaseBuild.options = options
        if !options.platforms.isEmpty {
            BaseBuild.platforms = options.platforms
        }
    }
}

class ArgumentOptions {
    private let arguments: [String]
    var enableDebug: Bool = false
    var enableSplitPlatform: Bool = false
    var enableGPL: Bool = false
    var platforms: [PlatformType] = []
    var releaseVersion: String = "0.0.0"

    init() {
        self.arguments = []
    }

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func contains(_ argument: String) -> Bool {
        return self.arguments.firstIndex(of: argument) != nil
    }

    static func parse(_ arguments: [String]) throws -> ArgumentOptions {
        let options = ArgumentOptions(arguments: Array(arguments.dropFirst()))
        for argument in arguments {
            switch argument {
            case "enable-debug":
                options.enableDebug = true
            case "enable-gpl":
                options.enableGPL = true
            case "enable-split-platform":
                options.enableSplitPlatform = true
            default:
                if argument.hasPrefix("version=") {
                    let version = String(argument.suffix(argument.count - "version=".count))
                    options.releaseVersion = version
                }
                if argument.hasPrefix("platform=") {
                    let values = String(argument.suffix(argument.count - "platform=".count))
                    for val in values.split(separator: ",") {
                        let platformStr = val.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        switch platformStr {
                        case "ios":
                            options.platforms += [PlatformType.ios, PlatformType.isimulator]
                        case "tvos":
                            options.platforms += [PlatformType.tvos, PlatformType.tvsimulator]
                        case "xros":
                            options.platforms += [PlatformType.xros, PlatformType.xrsimulator]
                        default:
                            guard let other = PlatformType(rawValue: platformStr) else { throw NSError(domain: "unknown platform: \(val)", code: 1) }
                            if !options.platforms.contains(other) {
                                options.platforms += [other]
                            }
                        }
                    }
                }
            }
        }

        return options
    }
}

class BaseBuild {
    static let defaultPath = "/Library/Frameworks/Python.framework/Versions/Current/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    static var platforms = PlatformType.allCases
    static var options = ArgumentOptions()
    static let splitPlatformGroups = [
        PlatformType.macos.rawValue: [PlatformType.macos, PlatformType.maccatalyst],
        PlatformType.ios.rawValue: [PlatformType.ios, PlatformType.isimulator],
        PlatformType.tvos.rawValue: [PlatformType.tvos, PlatformType.tvsimulator],
        PlatformType.xros.rawValue: [PlatformType.xros, PlatformType.xrsimulator]
    ]
    let library: Library
    let directoryURL: URL
    let xcframeworkDirectoryURL: URL
    var pullLatestVersion = false

    init(library: Library) {
        self.library = library
        directoryURL = URL.currentDirectory + "\(library.rawValue)-\(library.version)"
        xcframeworkDirectoryURL = URL.currentDirectory + ["release", "xcframework"]
    }

    func beforeBuild() throws {
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            return
        }

        if pullLatestVersion {
            try! Utility.launch(path: "/usr/bin/git", arguments: ["-c", "advice.detachedHead=false", "clone", "--recursive", "--depth", "1", library.url, directoryURL.path])
        } else {
            try! Utility.launch(path: "/usr/bin/git", arguments: ["-c", "advice.detachedHead=false", "clone", "--recursive", "--depth", "1", "--branch", library.version, library.url, directoryURL.path])
        }

        let patch = URL.currentDirectory + "../Sources/BuildScripts/patch/\(library.rawValue)"
        if FileManager.default.fileExists(atPath: patch.path) {
            _ = try? Utility.launch(path: "/usr/bin/git", arguments: ["checkout", "."], currentDirectoryURL: directoryURL)
            let fileNames = try! FileManager.default.contentsOfDirectory(atPath: patch.path).sorted()
            for fileName in fileNames where fileName.hasSuffix(".patch") {
                try! Utility.launch(path: "/usr/bin/git", arguments: ["apply", "\((patch + fileName).path)"], currentDirectoryURL: directoryURL)
            }
        }
    }

    func buildALL() throws {
        try beforeBuild()
        try? FileManager.default.removeItem(at: URL.currentDirectory + library.rawValue)
        try? FileManager.default.removeItem(at: directoryURL.appendingPathExtension("log"))
        for platform in BaseBuild.platforms {
            for arch in architectures(platform) {
                try build(platform: platform, arch: arch)
            }
        }
        try createXCFramework()
        try packageRelease()
        try afterBuild()
    }

    func afterBuild() throws {
        try generatePackageManagerFile()
    }

    func architectures(_ platform: PlatformType) -> [ArchType] {
        platform.architectures
    }

    func platforms() -> [PlatformType] {
        BaseBuild.platforms
    }

    func build(platform: PlatformType, arch: ArchType) throws {
        let buildURL = scratch(platform: platform, arch: arch)
        try? FileManager.default.createDirectory(at: buildURL, withIntermediateDirectories: true, attributes: nil)
        let environ = environment(platform: platform, arch: arch)
        if FileManager.default.fileExists(atPath: (directoryURL + "meson.build").path) {
            if Utility.shell("which meson") == nil {
                Utility.shell("brew install meson")
            }
            if Utility.shell("which ninja") == nil {
                Utility.shell("brew install ninja")
            }

            let crossFile = createMesonCrossFile(platform: platform, arch: arch)
            let meson = Utility.shell("which meson", isOutput: true)!
            try Utility.launch(path: meson, arguments: ["setup", buildURL.path, "--cross-file=\(crossFile.path)"] + arguments(platform: platform, arch: arch), currentDirectoryURL: directoryURL, environment: environ)
            try Utility.launch(path: meson, arguments: ["compile", "--clean"], currentDirectoryURL: buildURL, environment: environ)
            try Utility.launch(path: meson, arguments: ["compile", "--verbose"], currentDirectoryURL: buildURL, environment: environ)
            try Utility.launch(path: meson, arguments: ["install"], currentDirectoryURL: buildURL, environment: environ)
        } else if FileManager.default.fileExists(atPath: (directoryURL + wafPath()).path) {
            let waf = (directoryURL + wafPath()).path
            try Utility.launch(path: waf, arguments: ["configure"] + arguments(platform: platform, arch: arch), currentDirectoryURL: directoryURL, environment: environ)
            try Utility.launch(path: waf, arguments: wafBuildArg(), currentDirectoryURL: directoryURL, environment: environ)
            try Utility.launch(path: waf, arguments: ["install"] + wafInstallArg(), currentDirectoryURL: directoryURL, environment: environ)
        } else {
            try configure(buildURL: buildURL, environ: environ, platform: platform, arch: arch)
            try Utility.launch(path: "/usr/bin/make", arguments: ["-j8"], currentDirectoryURL: buildURL, environment: environ)
            try Utility.launch(path: "/usr/bin/make", arguments: ["-j8", "install"], currentDirectoryURL: buildURL, environment: environ)
        }
    }

    func wafPath() -> String {
        "./waf"
    }

    func wafBuildArg() -> [String] {
        ["build"]
    }

    func wafInstallArg() -> [String] {
        []
    }

    func configure(buildURL: URL, environ: [String: String], platform: PlatformType, arch: ArchType) throws {
        let autogen = directoryURL + "autogen.sh"
        if FileManager.default.fileExists(atPath: autogen.path) {
            var environ = environ
            environ["NOCONFIGURE"] = "1"
            try Utility.launch(executableURL: autogen, arguments: [], currentDirectoryURL: directoryURL, environment: environ)
        }
        let makeLists = directoryURL + "CMakeLists.txt"
        if FileManager.default.fileExists(atPath: makeLists.path) {
            if Utility.shell("which cmake") == nil {
                Utility.shell("brew install cmake")
            }
            let cmake = Utility.shell("which cmake", isOutput: true)!
            let thinDirPath = thinDir(platform: platform, arch: arch).path
            var arguments = [
                makeLists.path,
                "-DCMAKE_VERBOSE_MAKEFILE=0",
                "-DCMAKE_BUILD_TYPE=Release",
                "-DCMAKE_OSX_SYSROOT=\(platform.sdk.lowercased())",
                "-DCMAKE_OSX_ARCHITECTURES=\(arch.rawValue)",
                "-DCMAKE_SYSTEM_NAME=\(platform.cmakeSystemName)",
                "-DCMAKE_SYSTEM_PROCESSOR=\(arch.rawValue)",
                "-DCMAKE_INSTALL_PREFIX=\(thinDirPath)",
                "-DBUILD_SHARED_LIBS=0",
                "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
            ]
            arguments.append(contentsOf: self.arguments(platform: platform, arch: arch))
            try Utility.launch(path: cmake, arguments: arguments, currentDirectoryURL: buildURL, environment: environ)
        } else {
            let configure = directoryURL + "configure"
            if !FileManager.default.fileExists(atPath: configure.path) {
                var bootstrap = directoryURL + "bootstrap"
                if !FileManager.default.fileExists(atPath: bootstrap.path) {
                    bootstrap = directoryURL + ".bootstrap"
                }
                if FileManager.default.fileExists(atPath: bootstrap.path) {
                    try Utility.launch(executableURL: bootstrap, arguments: [], currentDirectoryURL: directoryURL, environment: environ)
                }
            }
            var arguments = [
                "--prefix=\(thinDir(platform: platform, arch: arch).path)",
            ]
            arguments.append(contentsOf: self.arguments(platform: platform, arch: arch))
            try Utility.launch(executableURL: configure, arguments: arguments, currentDirectoryURL: buildURL, environment: environ)
        }
    }

    func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        let cFlags = cFlags(platform: platform, arch: arch).joined(separator: " ")
        let ldFlags = ldFlags(platform: platform, arch: arch).joined(separator: " ")
        let pkgConfigPath = platform.pkgConfigPath(arch: arch)
        let pkgConfigPathDefault = Utility.shell("pkg-config --variable pc_path pkg-config", isOutput: true)!
        return [
            "LC_CTYPE": "C",
            "CC": "/usr/bin/clang",
            "CXX": "/usr/bin/clang++",
            "CURRENT_ARCH": arch.rawValue,
            "CFLAGS": cFlags,
            "CPPFLAGS": cFlags,
            "CXXFLAGS": cFlags,
            "ASMFLAGS": cFlags,
            "LDFLAGS": ldFlags,
            "PKG_CONFIG_LIBDIR": pkgConfigPath + pkgConfigPathDefault,
            "PATH": BaseBuild.defaultPath,
        ]
    }

    func cFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var cFlags = platform.cFlags(arch: arch)
        let librarys = flagsDependencelibrarys()
        for library in librarys {
            let path = URL.currentDirectory + [library.rawValue, platform.rawValue, "thin", arch.rawValue]
            if FileManager.default.fileExists(atPath: path.path) {
                cFlags.append("-I\(path.path)/include")
            }
        }
        return cFlags
    }

    func ldFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var ldFlags = platform.ldFlags(arch: arch)
        let librarys = flagsDependencelibrarys()
        for library in librarys {
            let path = URL.currentDirectory + [library.rawValue, platform.rawValue, "thin", arch.rawValue]
            if FileManager.default.fileExists(atPath: path.path) {
                var libname = library.rawValue
                if libname.hasPrefix("lib") {
                    libname = String(libname.dropFirst(3))
                }
                ldFlags.append("-L\(path.path)/lib")
                ldFlags.append("-l\(libname)")
            }
        }
        return ldFlags
    }

    func flagsDependencelibrarys() -> [Library] {
        []
    }

    func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        return []
    }

    func frameworks() throws -> [String] {
        [library.rawValue]
    }

    private func dSYMPath(forFrameworkPath frameworkPath: String) -> String? {
        let frameworkURL = URL(fileURLWithPath: frameworkPath)
        let dSYMURL = frameworkURL.deletingPathExtension().appendingPathExtension("framework.dSYM")
        guard FileManager.default.fileExists(atPath: dSYMURL.path) else {
            return nil
        }
        return dSYMURL.path
    }

    private func generateDSYMIfPossible(forFramework framework: String, at frameworkDir: URL) throws {
        let binaryURL = frameworkDir + framework
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            return
        }

        let dSYMURL = frameworkDir.deletingPathExtension().appendingPathExtension("framework.dSYM")
        try? FileManager.default.removeItem(at: dSYMURL)

        do {
            try Utility.launch(
                path: "/usr/bin/xcrun",
                arguments: ["dsymutil", binaryURL.path, "-o", dSYMURL.path]
            )
        } catch {
            try? FileManager.default.removeItem(at: dSYMURL)
        }
    }

    func createXCFramework() throws {
        try? Utility.removeFiles(extensions: [".xcframework"], currentDirectoryURL: self.xcframeworkDirectoryURL)

        var frameworks: [String] = []
        let libNames = try self.frameworks()
        for libName in libNames {
            if libName.hasPrefix("lib") {
                frameworks.append("Lib" + libName.dropFirst(3))
            } else {
                frameworks.append(libName)
            }
        }
        for framework in frameworks {
            var frameworkGenerated = [PlatformType: String]()
            for platform in BaseBuild.platforms {
                if let frameworkPath = try createFramework(framework: framework, platform: platform) {
                    frameworkGenerated[platform] = frameworkPath
                }
            }
            try buildXCFramework(name: framework, paths: Array(frameworkGenerated.values))

            if BaseBuild.options.enableSplitPlatform {
                for (group, platforms) in BaseBuild.splitPlatformGroups {
                    var frameworkPaths: [String] = []
                    for platform in platforms {
                        if let frameworkPath = frameworkGenerated[platform] {
                            frameworkPaths.append(frameworkPath)
                        }
                    }
                    try buildXCFramework(name: "\(framework)-\(group)", paths: frameworkPaths)
                }
            }
        }
    }

    private func buildXCFramework(name: String, paths: [String]) throws {
        if paths.isEmpty {
            return
        }

        var arguments = ["-create-xcframework"]
        for frameworkPath in paths {
            arguments.append("-framework")
            arguments.append(frameworkPath)

            if let dSYMPath = dSYMPath(forFrameworkPath: frameworkPath) {
                arguments.append("-debug-symbols")
                arguments.append(dSYMPath)
            }
        }
        arguments.append("-output")
        let XCFrameworkFile = self.xcframeworkDirectoryURL + [name + ".xcframework"]
        arguments.append(XCFrameworkFile.path)
        if FileManager.default.fileExists(atPath: XCFrameworkFile.path) {
            try? FileManager.default.removeItem(at: XCFrameworkFile)
        }
        try Utility.launch(path: "/usr/bin/xcodebuild", arguments: arguments)
    }

    func createFramework(framework: String, platform: PlatformType) throws -> String? {
        let platformDir = URL.currentDirectory + [library.rawValue, platform.rawValue]
        if !FileManager.default.fileExists(atPath: platformDir.path) {
            return nil
        }
        let frameworkDir = URL.currentDirectory + [library.rawValue, platform.rawValue, "\(framework).framework"]
        if !platforms().contains(platform) {
            if FileManager.default.fileExists(atPath: frameworkDir.path) {
                return frameworkDir.path
            } else {
                return nil
            }
        }
        try? FileManager.default.removeItem(at: frameworkDir)
        try FileManager.default.createDirectory(at: frameworkDir, withIntermediateDirectories: true, attributes: nil)
        var arguments = ["-create"]
        for arch in platform.architectures {
            let prefix = thinDir(platform: platform, arch: arch)
            if !FileManager.default.fileExists(atPath: prefix.path) {
                return nil
            }
            let libname = framework.hasPrefix("lib") || framework.hasPrefix("Lib") ? framework : "lib" + framework
            var libPath = prefix + ["lib", "\(libname).a"]
            if !FileManager.default.fileExists(atPath: libPath.path) {
                libPath = prefix + ["lib", "\(libname).dylib"]
            }
            arguments.append(libPath.path)
            var headerURL: URL = prefix + "include" + framework
            if !FileManager.default.fileExists(atPath: headerURL.path) {
                headerURL = prefix + "include"
            }
            try? FileManager.default.copyItem(at: headerURL, to: frameworkDir + "Headers")
        }
        arguments.append("-output")
        arguments.append((frameworkDir + framework).path)
        try Utility.launch(path: "/usr/bin/lipo", arguments: arguments)
        try FileManager.default.createDirectory(at: frameworkDir + "Modules", withIntermediateDirectories: true, attributes: nil)
        var modulemap = """
        framework module \(framework) [system] {
            umbrella "."

        """
        frameworkExcludeHeaders(framework).forEach { header in
            modulemap += """
                exclude header "\(header).h"

            """
        }
        modulemap += """
            export *
        }
        """
        FileManager.default.createFile(atPath: frameworkDir.path + "/Modules/module.modulemap", contents: modulemap.data(using: .utf8), attributes: nil)
        createPlist(path: frameworkDir.path + "/Info.plist", name: framework, minVersion: "100.0", platform: platform.sdk)
        try fixShallowBundles(framework: framework, platform: platform, frameworkDir: frameworkDir)
        try generateDSYMIfPossible(forFramework: framework, at: frameworkDir)
        return frameworkDir.path
    }

    func fixShallowBundles(framework: String, platform: PlatformType, frameworkDir: URL) throws {
        guard platform == .macos else { return }

        let infoPlistPath = frameworkDir + "Info.plist"
        let versionsPath = frameworkDir + "Versions"

        var isDirectory: ObjCBool = false
        let frameworkExists = FileManager.default.fileExists(atPath: frameworkDir.path, isDirectory: &isDirectory)
        let hasInfoPlist = FileManager.default.fileExists(atPath: infoPlistPath.path)
        let hasVersions = FileManager.default.fileExists(atPath: versionsPath.path, isDirectory: &isDirectory) && isDirectory.boolValue

        if frameworkExists && hasInfoPlist && !hasVersions {
            print("Fixing \(framework).framework bundle structure...")

            let versionAResourcesPath = frameworkDir + ["Versions", "A", "Resources"]
            try FileManager.default.createDirectory(at: versionAResourcesPath, withIntermediateDirectories: true, attributes: nil)

            let newInfoPlistPath = versionAResourcesPath + "Info.plist"
            try FileManager.default.moveItem(at: infoPlistPath, to: newInfoPlistPath)

            let binaryPath = frameworkDir + framework
            let newBinaryPath = frameworkDir + ["Versions", "A", framework]
            if FileManager.default.fileExists(atPath: binaryPath.path) {
                try FileManager.default.moveItem(at: binaryPath, to: newBinaryPath)
            }

            let licensePath = frameworkDir + "LICENSE"
            if FileManager.default.fileExists(atPath: licensePath.path) {
                let newLicensePath = frameworkDir + ["Versions", "A", "LICENSE"]
                try FileManager.default.moveItem(at: licensePath, to: newLicensePath)
            }

            let currentLinkPath = frameworkDir + ["Versions", "Current"]
            try? FileManager.default.removeItem(at: currentLinkPath)
            try FileManager.default.createSymbolicLink(atPath: currentLinkPath.path, withDestinationPath: "A")

            let binaryLinkPath = frameworkDir.appendingPathComponent(framework)
            try? FileManager.default.removeItem(at: binaryLinkPath)
            try FileManager.default.createSymbolicLink(atPath: binaryLinkPath.path, withDestinationPath: "Versions/Current/\(framework)")

            let resourcesLinkPath = frameworkDir.appendingPathComponent("Resources")
            try? FileManager.default.removeItem(at: resourcesLinkPath)
            try FileManager.default.createSymbolicLink(atPath: resourcesLinkPath.path, withDestinationPath: "Versions/Current/Resources")

            print("\(framework).framework structure fixed")
        }
    }
}
