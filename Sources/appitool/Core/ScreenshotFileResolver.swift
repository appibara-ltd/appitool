import Foundation

/// Batch of image files belonging to a single localization locale and store image/display type.
struct ScreenshotUploadBatch<ImageType: Sendable & Equatable>: Sendable {
    let locale: String
    let type: ImageType
    let files: [URL]
}

/// Resolves and validates local screenshot/visual image files from file or directory paths.
enum ScreenshotFileResolver: Sendable {
    static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg"]

    /// Resolves either an explicit flat upload (`-l` / `-t` + file(s)/flat dir) or a structured
    /// `<locale>/<type>/*.{png,jpg,jpeg}` directory tree (defaulting to `defaultDirectory()` when `paths` is empty).
    static func resolveUploadBatches<ImageType: Sendable & Equatable>(
        paths: [String],
        defaultDirectory: () throws -> URL,
        localeFilter: String?,
        typeFilter: String?,
        defaultFlatType: ImageType? = nil,
        storeDisplayName: String,
        downloadHintCommand: String,
        parseType: (String) throws -> ImageType
    ) throws -> (sourceRoot: URL?, batches: [ScreenshotUploadBatch<ImageType>]) {
        let fm = FileManager.default
        let cleanLocale = localeFilter
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let cleanType = typeFilter
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let parsedTypeFilter = try cleanType.map(parseType)
        let rawPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if rawPaths.isEmpty {
            let root = try defaultDirectory().standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                throw CommandError("Screenshot directory not found: \(root.path). Run '\(downloadHintCommand)' first or pass explicit image path(s).")
            }
            let batches = try scanStructuredTree(
                at: root,
                localeFilter: cleanLocale,
                typeFilter: parsedTypeFilter,
                rawTypeFilter: cleanType,
                storeDisplayName: storeDisplayName,
                parseType: parseType
            )
            return (root, batches)
        }

        if rawPaths.count == 1 {
            let candidate = expandPath(rawPaths[0])
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                let directFiles = try directImageFiles(in: candidate)
                if !directFiles.isEmpty {
                    guard let cleanLocale else {
                        throw CommandError("Uploading flat images from '\(rawPaths[0])' requires -l, --locale (or pass a <locale>/<type>/ directory tree).")
                    }
                    guard let targetType = parsedTypeFilter ?? defaultFlatType else {
                        throw CommandError("Uploading flat images from '\(rawPaths[0])' requires -t, --type (or pass a <locale>/<type>/ directory tree).")
                    }
                    for file in directFiles {
                        try validateNonEmptyFile(at: file)
                    }
                    return (nil, [ScreenshotUploadBatch(locale: cleanLocale, type: targetType, files: directFiles)])
                }

                // If -l was provided and `candidate` looks like a 1-level `<type>/` directory (e.g. `.../<locale>/`),
                // treat direct subdirectories containing images as `<type>/` slots for `cleanLocale`.
                let childDirs = try sortedSubdirectories(in: candidate)
                if let cleanLocale,
                   !childDirs.contains(where: { $0.lastPathComponent.caseInsensitiveCompare(cleanLocale) == .orderedSame }),
                   try childDirs.contains(where: { try !directImageFiles(in: $0).isEmpty }) {
                    let batches = try scanTypeDirectories(
                        in: candidate,
                        locale: cleanLocale,
                        typeFilter: parsedTypeFilter,
                        parseType: parseType
                    )
                    guard !batches.isEmpty else {
                        let typeText = cleanType.map { " matching type '\($0)'" } ?? ""
                        throw CommandError("No PNG or JPEG screenshots found under '\(candidate.path)'\(typeText) (\(storeDisplayName)).")
                    }
                    return (candidate, batches)
                }

                let batches = try scanStructuredTree(
                    at: candidate,
                    localeFilter: cleanLocale,
                    typeFilter: parsedTypeFilter,
                    rawTypeFilter: cleanType,
                    storeDisplayName: storeDisplayName,
                    parseType: parseType
                )
                return (candidate, batches)
            }
        }

        guard let cleanLocale else {
            throw CommandError("Uploading explicit image file(s) requires -l, --locale (or pass a <locale>/<type>/ directory tree).")
        }
        guard let targetType = parsedTypeFilter ?? defaultFlatType else {
            throw CommandError("Uploading explicit image file(s) requires -t, --type (or pass a <locale>/<type>/ directory tree).")
        }
        let files = try resolveImageFiles(from: rawPaths)
        return (nil, [ScreenshotUploadBatch(locale: cleanLocale, type: targetType, files: files)])
    }

    static func resolveImageFiles(from rawPaths: [String]) throws -> [URL] {
        let fm = FileManager.default
        var resolved: [URL] = []
        var seen = Set<String>()

        for raw in rawPaths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let url = expandPath(trimmed)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw CommandError("Image file or directory not found: \(trimmed)")
            }

            if isDir.boolValue {
                let matching = try directImageFiles(in: url)
                guard !matching.isEmpty else {
                    throw CommandError("No PNG or JPEG images found in directory: \(trimmed)")
                }

                for std in matching {
                    try validateNonEmptyFile(at: std)
                    if seen.insert(std.path).inserted {
                        resolved.append(std)
                    }
                }
            } else {
                let ext = url.pathExtension.lowercased()
                guard supportedExtensions.contains(ext) else {
                    throw CommandError("Unsupported image format '.\(url.pathExtension)' at '\(trimmed)'. Supported formats: .png, .jpg, .jpeg.")
                }
                try validateNonEmptyFile(at: url)
                if seen.insert(url.path).inserted {
                    resolved.append(url)
                }
            }
        }

        guard !resolved.isEmpty else {
            throw CommandError("No valid PNG or JPEG image files were provided.")
        }

        return resolved
    }

    private static func scanStructuredTree<ImageType: Sendable & Equatable>(
        at root: URL,
        localeFilter: String?,
        typeFilter: ImageType?,
        rawTypeFilter: String?,
        storeDisplayName: String,
        parseType: (String) throws -> ImageType
    ) throws -> [ScreenshotUploadBatch<ImageType>] {
        let localeDirs = try sortedSubdirectories(in: root)
        var batches: [ScreenshotUploadBatch<ImageType>] = []

        for localeDir in localeDirs {
            let folderLocale = localeDir.lastPathComponent
            if let localeFilter, folderLocale.caseInsensitiveCompare(localeFilter) != .orderedSame {
                continue
            }
            let effectiveLocale = localeFilter ?? folderLocale
            let localeBatches = try scanTypeDirectories(
                in: localeDir,
                locale: effectiveLocale,
                typeFilter: typeFilter,
                parseType: parseType
            )
            batches.append(contentsOf: localeBatches)
        }

        guard !batches.isEmpty else {
            var filters: [String] = []
            if let localeFilter { filters.append("locale '\(localeFilter)'") }
            if let rawTypeFilter { filters.append("type '\(rawTypeFilter)'") }
            let filterText = filters.isEmpty ? "" : " matching \(filters.joined(separator: " and "))"
            throw CommandError(
                "No PNG or JPEG screenshots found under '\(root.path)'\(filterText) (\(storeDisplayName)). Expected <locale>/<type>/*.{png,jpg,jpeg} folders or pass explicit file path(s)."
            )
        }

        return batches
    }

    private static func scanTypeDirectories<ImageType: Sendable & Equatable>(
        in localeDir: URL,
        locale: String,
        typeFilter: ImageType?,
        parseType: (String) throws -> ImageType
    ) throws -> [ScreenshotUploadBatch<ImageType>] {
        let typeDirs = try sortedSubdirectories(in: localeDir)
        var batches: [ScreenshotUploadBatch<ImageType>] = []

        for typeDir in typeDirs {
            let files = try directImageFiles(in: typeDir)
            if files.isEmpty { continue }

            let parsedType: ImageType
            do {
                parsedType = try parseType(typeDir.lastPathComponent)
            } catch {
                throw CommandError("Unrecognized screenshot type folder '\(typeDir.path)': \(error.localizedDescription)")
            }

            for file in files {
                try validateNonEmptyFile(at: file)
            }

            if let typeFilter, parsedType != typeFilter {
                continue
            }

            batches.append(ScreenshotUploadBatch(locale: locale, type: parsedType, files: files))
        }

        return batches
    }

    private static func sortedSubdirectories(in dir: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { item in
            (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }.map(\.standardizedFileURL)
    }

    private static func directImageFiles(in dir: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { item in
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { return false }
            return supportedExtensions.contains(item.pathExtension.lowercased())
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }.map(\.standardizedFileURL)
    }

    static func mimeType(for url: URL) -> String {
        url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
    }

    static func expandPath(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        let expanded: String
        if trimmed.hasPrefix("~/") || trimmed.hasPrefix("~\\") {
            expanded = fm.homeDirectoryForCurrentUser.appendingPathComponent(String(trimmed.dropFirst(2))).path
        } else if trimmed == "~" {
            expanded = fm.homeDirectoryForCurrentUser.path
        } else {
            expanded = trimmed
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    static func detectImageExtension(
        contentType: String?,
        data: Data,
        fallback: String = "png"
    ) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "png"
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "jpg"
        }
        if bytes.count >= 12,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }

        if let normalizedType = contentType?
            .split(separator: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            switch normalizedType {
            case "image/png":
                return "png"
            case "image/jpeg", "image/jpg":
                return "jpg"
            case "image/webp":
                return "webp"
            default:
                break
            }
        }

        let cleanFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleanFallback.isEmpty ? "png" : cleanFallback
    }

    static func orderPrefixedFilename(
        index: Int,
        totalCount: Int,
        originalName: String?,
        fallbackStem: String? = nil,
        fileExtension: String
    ) -> String {
        let width = max(2, String(max(totalCount, index)).count)
        let prefix = String(format: "%0\(width)d", max(1, index))
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let finalExt = ext.isEmpty ? "png" : ext

        guard let originalName, !originalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(prefix).\(finalExt)"
        }

        let lastComponent = (originalName as NSString).lastPathComponent
        var stem = (lastComponent as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = stem.range(of: #"^\d{2,}[_-]"#, options: .regularExpression) {
            stem.removeSubrange(range)
        }
        for char in ["/", "\\", ":", "\0"] {
            stem = stem.replacingOccurrences(of: char, with: "_")
        }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty {
            let cleanFallback = fallbackStem?.trimmingCharacters(in: .whitespacesAndNewlines)
            stem = (cleanFallback?.isEmpty == false) ? cleanFallback! : "screenshot"
        }
        return "\(prefix)_\(stem).\(finalExt)"
    }

    private static func validateNonEmptyFile(at url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw CommandError("Image file is empty (0 bytes): \(url.path)")
        }
    }
}
