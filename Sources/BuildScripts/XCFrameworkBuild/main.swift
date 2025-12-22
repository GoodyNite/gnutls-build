import Foundation

do {
    let options = try ArgumentOptions.parse(CommandLine.arguments)
    try Build.performCommand(options)

    try BuildGmp().buildALL()
    try BuildNettle().buildALL()
    try BuildGnutls().buildALL()
} catch {
    print(error.localizedDescription)
    exit(1)
}


enum Library: String, CaseIterable {
    case gnutls, gmp, nettle
    var version: String {
        switch self {
        case .gnutls:
            return "3.8.11"
        case .nettle:
            return "nettle_3.10_release_20240616"
        case .gmp:
            return "v6.2.1"
        }
    }

    var url: String {
        switch self {
        case .gnutls:
            return "https://github.com/gnutls/gnutls"
        case .nettle:
            return "https://git.lysator.liu.se/nettle/nettle"
        case .gmp:
            return "https://github.com/alisw/GMP"
        }
    }


    // for generate Package.swift
    var targets : [PackageTarget] {
        switch self {
        case .gnutls:
            return  [
                .target(
                    name: "gnutls",
                    url: "https://github.com/mpvkit/gnutls-build/releases/download/\(BaseBuild.options.releaseVersion)/gnutls.xcframework.zip",
                    checksum: "https://github.com/mpvkit/gnutls-build/releases/download/\(BaseBuild.options.releaseVersion)/gnutls.xcframework.checksum.txt"
                ),
            ]
        case .nettle:
            return  [
                .target(
                    name: "nettle",
                    url: "https://github.com/mpvkit/gnutls-build/releases/download/\(BaseBuild.options.releaseVersion)/nettle.xcframework.zip",
                    checksum: "https://github.com/mpvkit/gnutls-build/releases/download/\(BaseBuild.options.releaseVersion)/nettle.xcframework.checksum.txt"
                ),
                .target(
                    name: "hogweed",
                    url: "https://github.com/mpvkit/gnutls-build/releases/download/\(BaseBuild.options.releaseVersion)/hogweed.xcframework.zip",
                    checksum: "https://github.com/mpvkit/gnutls-build/releases/download/\(BaseBuild.options.releaseVersion)/hogweed.xcframework.checksum.txt"
                ),
            ]
        case .gmp:
            return  [
                .target(
                    name: "gmp",
                    url: "https://github.com/mpvkit/gnutls-build/releases/download/\(BaseBuild.options.releaseVersion)/gmp.xcframework.zip",
                    checksum: "https://github.com/mpvkit/gnutls-build/releases/download/\(BaseBuild.options.releaseVersion)/gmp.xcframework.checksum.txt"
                ),
            ]
        }
    }
}

private class BuildGmp: BaseBuild {
    init() {
        super.init(library: .gmp)
        // if Utility.shell("which makeinfo") == nil {
        //     Utility.shell("brew install texinfo")
        // }
    }

    override func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        [
            "--disable-maintainer-mode",
            "--disable-assembly",
            "--with-pic",
            "--enable-static",
            "--disable-shared",
            "--disable-fast-install",
            "--host=\(platform.host(arch: arch))",
            "--prefix=\(thinDir(platform: platform, arch: arch).path)",
        ]
    }
}
private class BuildNettle: BaseBuild {
    init() {
        super.init(library: .nettle)
    }

    override func beforeBuild() throws {
        if Utility.shell("which autoconf") == nil {
            Utility.shell("brew install autoconf")
        }

        try super.beforeBuild()
    }

    override func flagsDependencelibrarys() -> [Library] {
        [.gmp]
    }

    override func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        [
            "--disable-assembler",
            "--disable-openssl",
            "--disable-gcov",
            "--disable-documentation",
            "--enable-pic",
            "--enable-static",
            "--disable-shared",
            "--disable-dependency-tracking",
            "--host=\(platform.host(arch: arch))",
            "--prefix=\(thinDir(platform: platform, arch: arch).path)",
//                arch == .arm64 || arch == .arm64e ? "--enable-arm-neon" : "--enable-x86-aesni",
        ]
    }

    override func frameworks() throws -> [String] {
        [library.rawValue, "hogweed"]
    }
}

private class BuildGnutls: BaseBuild {
    init() {
        super.init(library: .gnutls)
    }

    override func beforeBuild() throws {
        if Utility.shell("which automake") == nil {
            Utility.shell("brew install automake")
        }
        if Utility.shell("which gtkdocize") == nil {
            Utility.shell("brew install gtk-doc")
        }
        if Utility.shell("which wget") == nil {
            Utility.shell("brew install wget")
        }
        if Utility.shell("brew list bison") == nil {
            Utility.shell("brew install bison")
        }
        if Utility.shell("which glibtoolize") == nil {
            Utility.shell("brew install libtool")
        }
        if Utility.shell("which asn1Parser") == nil {
            Utility.shell("brew install libtasn1")
        }

        try super.beforeBuild()
    }

    override func flagsDependencelibrarys() -> [Library] {
        [.gmp, .nettle]
    }

    override func ldFlags(platform: PlatformType, arch: ArchType) -> [String] {
        var ldFlags = super.ldFlags(platform: platform, arch: arch)
        ldFlags.append("-lhogweed")
        return ldFlags
    }

    override func environment(platform: PlatformType, arch: ArchType) -> [String: String] {
        var env = super.environment(platform: platform, arch: arch)
        // 需要bison的版本大于2.4,系统自带的/usr/bin/bison是 2.3
        env["PATH"] = "/usr/local/opt/bison/bin:/opt/homebrew/opt/bison/bin:" + (env["PATH"] ?? "")
        return env
    }

    override func configure(buildURL: URL, environ: [String: String], platform: PlatformType, arch: ArchType) throws {
        try super.configure(buildURL: buildURL, environ: environ, platform: platform, arch: arch)
        let path = directoryURL + "lib/accelerated/aarch64/Makefile.in"
        if let data = FileManager.default.contents(atPath: path.path), var str = String(data: data, encoding: .utf8) {
            str = str.replacingOccurrences(of: "AM_CCASFLAGS =", with: "#AM_CCASFLAGS=")
            try! str.write(toFile: path.path, atomically: true, encoding: .utf8)
        }
    }

    override func arguments(platform: PlatformType, arch: ArchType) -> [String] {
        [
            "--with-included-libtasn1",
            "--with-included-unistring",
            "--without-brotli",
            "--without-idn",
            "--without-p11-kit",
            "--without-zlib",
            "--without-zstd",
            "--enable-hardware-acceleration",
            "--disable-openssl-compatibility",
            "--disable-code-coverage",
            "--disable-doc",
            "--disable-maintainer-mode",
            "--disable-manpages",
            "--disable-nls",
            "--disable-rpath",
            "--disable-doc",
            "--disable-tests",
            "--disable-tools",
            "--disable-full-test-suite",
            "--with-pic",
            "--enable-static",
            "--disable-shared",
            "--disable-fast-install",
            "--disable-dependency-tracking",
            "--host=\(platform.host(arch: arch))",
            "--prefix=\(thinDir(platform: platform, arch: arch).path)",
        ]
    }
}