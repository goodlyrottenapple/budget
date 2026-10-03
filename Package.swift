// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BudgetCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "BudgetCore", targets: ["BudgetCore"]),
               .library(name: "BudgetPersistence", targets: ["BudgetPersistence"])],
    targets: [
        .target(name: "BudgetCore"),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore"]),
        .target(name: "BudgetPersistence", dependencies: ["BudgetCore"]),
        .testTarget(name: "BudgetPersistenceTests", dependencies: ["BudgetCore", "BudgetPersistence"]),
        .target(name: "BudgetBanking", dependencies: ["BudgetCore"], path: "App",
                exclude: ["Assets.xcassets", "BankIcons", "BudgetApp.swift", "Info.plist", "LogoDevView.swift", "Settings.bundle", "AppLock.swift"],
                sources: ["BankService.swift"]),
        .target(name: "BudgetSecurity", path: "App",
                exclude: ["Assets.xcassets", "BankIcons", "BudgetApp.swift", "Info.plist", "LogoDevView.swift", "Settings.bundle", "BankService.swift"],
                sources: ["AppLock.swift"]),
        .testTarget(name: "BudgetSecurityTests", dependencies: ["BudgetSecurity"]),
        .testTarget(name: "BudgetBankingTests", dependencies: ["BudgetBanking", "BudgetCore"],
                    resources: [.copy("Fixtures")])
    ]
)
