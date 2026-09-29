// swift-tools-version:5.9
//
// SwiftTerm 1.11.2 (github.com/migueldeicaza/SwiftTerm, MIT), vendored with the
// library target only and one patch — see PATCHES.md. The upstream manifest's
// executables, tests and benchmarks, and the packages they pull in, are left
// out: Termstead only links the library.

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
