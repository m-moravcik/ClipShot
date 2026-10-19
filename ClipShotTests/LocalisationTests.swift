import Foundation
import Testing
@testable import ClipShot

private let nbsp = "\u{00A0}"

/// The resolved text, with no-break spaces shown as spaces unless `keepNoBreak`.
private func text(_ resource: LocalizedStringResource, _ language: String, keepNoBreak: Bool = false) -> String {
    var resource = resource
    resource.locale = Locale(identifier: language)
    let value = String(localized: resource)
    return keepNoBreak ? value : value.replacingOccurrences(of: nbsp, with: " ")
}

/// The shipped catalog, resolved the way the app resolves it: Slavic plurals pick the right
/// form, and a count with two agreeing words (verb and noun) agrees in both.
struct CatalogPluralTests {
    @Test func slovakAndCzechCountForms() {
        #expect(text(Copy.About.copied(1), "sk") == "1 skopírovaná snímka")
        #expect(text(Copy.About.copied(3), "sk") == "3 skopírované snímky")
        #expect(text(Copy.About.copied(5), "sk") == "5 skopírovaných snímok")
        #expect(text(Copy.About.copied(1), "cs") == "1 zkopírovaný snímek")
        #expect(text(Copy.About.copied(4), "cs") == "4 zkopírované snímky")
        #expect(text(Copy.About.copied(12), "cs") == "12 zkopírovaných snímků")
        #expect(text(Copy.Retention.days(2), "sk") == "2 dni")
        #expect(text(Copy.Retention.days(30), "cs") == "30 dní")
    }

    @Test func verbAndNounAgreeInTheRetentionPreview() {
        #expect(text(Copy.Retention.wouldMove(1, "1 MB"), "sk") == "Do Koša by teraz išla 1 snímka (1 MB)")
        #expect(text(Copy.Retention.wouldMove(3, "1 MB"), "sk") == "Do Koša by teraz išli 3 snímky (1 MB)")
        #expect(text(Copy.Retention.wouldMove(12, "1 MB"), "sk") == "Do Koša by teraz išlo 12 snímok (1 MB)")
        #expect(text(Copy.Retention.wouldMove(2, "1 MB"), "cs") == "Do Koše by teď šly 2 snímky (1 MB)")
        #expect(text(Copy.Retention.wouldMove(1, "1 MB"), "de") == "Jetzt käme 1 Bildschirmfoto (1 MB) in den Papierkorb")
        #expect(text(Copy.Retention.wouldMove(2, "1 MB"), "es") == "Ahora irían a la Papelera 2 capturas (1 MB)")
        #expect(text(Copy.Retention.wouldMove(2, "1 MB"), "fr") == "2 captures (1 MB) iraient maintenant dans la Corbeille")
    }

    @Test func positionalArgumentsSurviveTheSubstitution() {
        #expect(text(Copy.Summary.lastCleanupToday("14:00", moved: 3), "sk") == "Posledné upratovanie dnes o 14:00, 3 snímky")
        #expect(text(Copy.Retention.moved(5, "2 MB"), "sk") == "Do Koša sa presunulo 5 snímok (2 MB).")
        #expect(text(Copy.Onboarding.stepOf(2, 3), "de") == "2 von 3")
    }

    @Test func slavicCountsAndOneLetterWordsDoNotEndALine() {
        #expect(text(Copy.Retention.days(5), "sk", keepNoBreak: true) == "5\(nbsp)dní")
        #expect(text(Copy.Retention.wouldMove(3, "1 MB"), "cs", keepNoBreak: true)
            == "Do Koše by teď šly 3\(nbsp)snímky (1 MB)")
        #expect(text(Copy.Onboarding.tidyBody(30), "sk", keepNoBreak: true).contains("po 30\(nbsp)dňoch"))
    }

    @Test func everyLanguageShips() throws {
        let languages = Set(Bundle.main.localizations)
        #expect(languages.isSuperset(of: ["en", "sk", "cs", "de", "es", "fr"]))
    }
}

/// `scripts/check-localisation.sh` must fail on a catalog that lacks a Slovak plural
/// category, wherever the plural sits.
struct LocalisationGateTests {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private func check(_ fixture: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            Self.repo.appendingPathComponent("scripts/check-localisation.sh").path,
            "--catalog", Self.repo.appendingPathComponent("ClipShotTests/Fixtures/l10n/\(fixture)").path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["L10N_LANGS"] = "en sk"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test(arguments: [
        "sk-missing-few-substitution-key.xcstrings",
        "sk-missing-few-first-substitution.xcstrings",
        "sk-missing-few-top-level.xcstrings",
    ])
    func failsWithoutSlovakFew(_ fixture: String) throws {
        let result = try check(fixture)
        #expect(result.status != 0, "\(fixture) passed: \(result.output)")
        #expect(result.output.contains("sk"))
        #expect(result.output.contains("['few'] missing"))
    }

    @Test func passesACompleteCatalog() throws {
        let result = try check("valid.xcstrings")
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("localisation: OK"))
    }
}
