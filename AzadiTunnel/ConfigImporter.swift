import Foundation

/// Advanced / developer-only override of App Group Psiphon config.
enum ConfigImporter {
    static func importFrom(url: URL) throws {
        SharedLogger.shared.log(.configImportOpened)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        SharedLogger.shared.logRaw("CONFIG_IMPORT_READ", detail: "bytes=\(data.count)")

        guard let text = String(data: data, encoding: .utf8) else {
            SharedLogger.shared.log(.configValidateFailed, detail: "reason=encoding")
            throw PsiphonConfigValidationError.invalidJSON
        }

        do {
            let normalized = try PsiphonConfigValidator.normalizedJSON(text)
            SharedLogger.shared.log(.configValidateOK)
            try SharedSettingsStore.shared.installPsiphonConfig(json: normalized, serverEntries: nil, bundled: false)
            SharedLogger.shared.log(.configSaved)
        } catch {
            SharedLogger.shared.log(.configValidateFailed, detail: "reason=\(error.localizedDescription)")
            throw error
        }
    }
}
