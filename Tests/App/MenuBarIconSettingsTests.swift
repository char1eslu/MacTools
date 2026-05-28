import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MacTools

@MainActor
final class MenuBarIconSettingsTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var rootDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MenuBarIconSettingsTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarIconSettingsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }

        try super.tearDownWithError()
    }

    func testImportPersistsCustomIconAndRecentItem() throws {
        let sourceURL = try makeImageFile(name: "status-icon.png", color: .systemBlue)
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        settings.importIcon(from: sourceURL, for: .light)
        settings.renderMode = .template
        let lightPayload = settings.imagePayload(for: NSAppearance(named: .aqua))
        let darkPayload = settings.imagePayload(for: NSAppearance(named: .darkAqua))

        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertEqual(settings.recentItems.count, 1)
        XCTAssertEqual(settings.recentItems.first?.displayName, "status-icon")
        XCTAssertFalse(lightPayload.isTemplate)
        XCTAssertFalse(darkPayload.isTemplate)

        let reloadedSettings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )
        let payload = reloadedSettings.imagePayload(for: NSAppearance(named: .aqua))

        XCTAssertTrue(reloadedSettings.hasCustomIcon)
        XCTAssertFalse(payload.isTemplate)
        XCTAssertEqual(payload.image.size, NSSize(width: 18, height: 18))
    }

    func testDefaultRootDirectoryUsesCurrentApplicationSupportScope() {
        XCTAssertEqual(
            AppStorageScope.applicationSupportRoot().lastPathComponent,
            AppStorageScope.applicationSupportDirectoryName
        )
    }

    func testImportImageRemovesPlainBackgroundByDefault() throws {
        let sourceURL = try makeImageFileWithBackground(name: "plain-background.png")
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        settings.importIcon(from: sourceURL, for: .light)
        let payload = settings.imagePayload(for: NSAppearance(named: .aqua))
        let cgImage = try XCTUnwrap(cgImage(from: payload.image))
        let pixel = try XCTUnwrap(pixelRGBA(in: cgImage, x: 0, y: 0))

        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertLessThan(pixel.alpha, 32)
    }

    func testDarkAppearanceFallsBackToLightCustomIcon() throws {
        let sourceURL = try makeImageFile(name: "shared.png", color: .systemRed)
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        settings.importIcon(from: sourceURL, for: .light)

        let payload = settings.imagePayload(for: NSAppearance(named: .darkAqua))

        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertEqual(payload.image.size, NSSize(width: 18, height: 18))
    }

    func testResetToDefaultClearsCustomSelectionButKeepsRecents() throws {
        let sourceURL = try makeImageFile(name: "reset.png", color: .systemGreen)
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        settings.importIcon(from: sourceURL, for: .light)
        XCTAssertFalse(settings.imagePayload(for: NSAppearance(named: .aqua)).isTemplate)

        settings.resetToDefault()

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertEqual(settings.recentItems.count, 1)
        XCTAssertTrue(settings.imagePayload(for: NSAppearance(named: .aqua)).isTemplate)
    }

    func testImagePayloadCacheInvalidatesWhenAnimationSpeedChanges() async throws {
        let sourceURL = try makeAnimatedGIFFile(name: "cache-speed.gif")
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        await settings.importAnimation(from: sourceURL, for: .light)
        XCTAssertEqual(settings.imagePayload(for: NSAppearance(named: .aqua)).manualSpeedMultiplier, 1)

        settings.manualAnimationSpeedMultiplier = 1.8

        XCTAssertEqual(settings.imagePayload(for: NSAppearance(named: .aqua)).manualSpeedMultiplier, 1.8)
    }

    func testRecentItemsKeepOnlyLatestSix() throws {
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        for index in 0..<7 {
            let sourceURL = try makeImageFile(name: "recent-\(index).png", color: .systemBlue)
            settings.importIcon(from: sourceURL)
        }

        XCTAssertEqual(settings.recentItems.count, 6)
        XCTAssertEqual(settings.recentItems.first?.displayName, "recent-6")
        XCTAssertFalse(settings.recentItems.contains { $0.displayName == "recent-0" })
    }

    func testAnimationSpeedSettingsPersistAndClampManualMultiplier() {
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        settings.animationSpeedMode = .adaptiveSystemLoad
        settings.manualAnimationSpeedMultiplier = 9

        let reloadedSettings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        XCTAssertEqual(reloadedSettings.animationSpeedMode, .adaptiveSystemLoad)
        XCTAssertEqual(
            reloadedSettings.manualAnimationSpeedMultiplier,
            MenuBarIconAnimationSpeedPolicy.maximumMultiplier
        )
    }

    func testPersistedChangesIncrementSettingsRevisionAfterStateChanges() throws {
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )
        let initialRevision = settings.settingsRevision

        settings.manualAnimationSpeedMultiplier = 1.4

        XCTAssertGreaterThan(settings.settingsRevision, initialRevision)
    }

    func testAdaptiveAnimationSpeedUsesAvailableSystemLoad() {
        let lowLoadMultiplier = MenuBarIconAnimationSpeedPolicy.multiplier(
            mode: .adaptiveSystemLoad,
            manualMultiplier: 1,
            systemLoad: MenuBarIconAnimationSystemLoad(cpuUsage: 0.1, gpuUsage: nil, memoryUsage: 0.2)
        )
        let highLoadMultiplier = MenuBarIconAnimationSpeedPolicy.multiplier(
            mode: .adaptiveSystemLoad,
            manualMultiplier: 1,
            systemLoad: MenuBarIconAnimationSystemLoad(cpuUsage: 0.9, gpuUsage: 0.8, memoryUsage: 0.7)
        )

        XCTAssertGreaterThan(highLoadMultiplier, lowLoadMultiplier)
        XCTAssertLessThanOrEqual(highLoadMultiplier, MenuBarIconAnimationSpeedPolicy.maximumMultiplier)
    }

    func testImportAnimatedGIFStoresLoopFrames() async throws {
        let sourceURL = try makeAnimatedGIFFile(name: "pulse.gif")
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        await settings.importAnimation(from: sourceURL, for: .light)
        let payload = settings.imagePayload(for: NSAppearance(named: .aqua))

        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertEqual(settings.recentItems.first?.mediaKind, .animation)
        XCTAssertTrue(payload.isAnimated)
        XCTAssertLessThanOrEqual(payload.animationFrames.count, MenuBarIconProcessing.maxAnimationFrames)
        XCTAssertEqual(payload.frameDuration, 1.0 / MenuBarIconProcessing.animationFramesPerSecond)
    }

    func testImportMP4StoresLoopFrames() async throws {
        let sourceURL = try makeMP4File(name: "runner.mp4")
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        await settings.importAnimation(from: sourceURL, for: .light)
        let payload = settings.imagePayload(for: NSAppearance(named: .aqua))

        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertEqual(settings.recentItems.first?.mediaKind, .animation)
        XCTAssertTrue(payload.isAnimated)
        XCTAssertGreaterThan(payload.animationFrames.count, 1)
    }

    func testLongButSmallAnimatedGIFIsAcceptedAndDownsampled() async throws {
        let sourceURL = try makeAnimatedGIFFile(name: "slow.gif", frameDelay: 2.5)
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        await settings.importAnimation(from: sourceURL, for: .light)
        let payload = settings.imagePayload(for: NSAppearance(named: .aqua))

        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertTrue(payload.isAnimated)
        XCTAssertLessThanOrEqual(payload.animationFrames.count, MenuBarIconProcessing.maxAnimationFrames)
    }

    func testRemoteGalleryCatalogLoadsFromFileURL() async throws {
        let galleryDirectory = rootDirectory.appendingPathComponent("Gallery", isDirectory: true)
        let catalogURL = try makeRemoteGalleryCatalog(in: galleryDirectory, useArchive: false)
        let provider = MenuBarIconGalleryProvider(
            source: .localDevelopment(catalogURL)
        )

        let snapshot = try await provider.loadCatalog()

        XCTAssertEqual(snapshot.catalog.assets.count, 1)
        XCTAssertEqual(snapshot.catalog.assets.first?.id, "remote-runner")
        XCTAssertTrue(snapshot.allowsFileResources)
    }

    func testRemoteGalleryAssetInstallsArchiveAndSettingsReadRemoteFrames() async throws {
        let galleryDirectory = rootDirectory.appendingPathComponent("GalleryArchive", isDirectory: true)
        let catalogURL = try makeRemoteGalleryCatalog(in: galleryDirectory, useArchive: true)
        let provider = MenuBarIconGalleryProvider(
            source: .localDevelopment(catalogURL)
        )
        let snapshot = try await provider.loadCatalog()
        let asset = try XCTUnwrap(snapshot.catalog.assets.first)
        let remoteStore = MenuBarIconRemoteAssetStore(
            rootDirectory: rootDirectory.appendingPathComponent("RemoteAssets", isDirectory: true)
        )
        let selection = try await remoteStore.installAsset(
            asset,
            contentBaseURL: snapshot.contentBaseURL,
            allowsFileResources: snapshot.allowsFileResources
        )
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory,
            remoteAssetStore: remoteStore
        )

        settings.useRemoteAsset(selection)
        let payload = settings.imagePayload(for: NSAppearance(named: .aqua))

        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertEqual(settings.selectedRemoteAsset?.id, "remote-runner")
        XCTAssertEqual(payload.animationFrames.count, 3)
        XCTAssertTrue(payload.isAnimated)
        XCTAssertEqual(settings.recentItems.count, 1)
        XCTAssertEqual(settings.recentItems.first?.displayName, "远程跑动")
        let recentItem = try XCTUnwrap(settings.recentItems.first)
        XCTAssertNotNil(recentItem.thumbnailFileName)
        XCTAssertEqual(settings.previewImage(for: recentItem).size, NSSize(width: 18, height: 18))
    }

    func testImportLocalIconClearsRemoteSelection() async throws {
        let galleryDirectory = rootDirectory.appendingPathComponent("GallerySelection", isDirectory: true)
        let catalogURL = try makeRemoteGalleryCatalog(in: galleryDirectory, useArchive: false)
        let provider = MenuBarIconGalleryProvider(
            source: .localDevelopment(catalogURL)
        )
        let snapshot = try await provider.loadCatalog()
        let asset = try XCTUnwrap(snapshot.catalog.assets.first)
        let remoteStore = MenuBarIconRemoteAssetStore(
            rootDirectory: rootDirectory.appendingPathComponent("RemoteAssets", isDirectory: true)
        )
        let selection = try await remoteStore.installAsset(
            asset,
            contentBaseURL: snapshot.contentBaseURL,
            allowsFileResources: snapshot.allowsFileResources
        )
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory,
            remoteAssetStore: remoteStore
        )
        settings.useRemoteAsset(selection)

        let localIconURL = try makeImageFile(name: "local.png", color: .systemPurple)
        settings.importIcon(from: localIconURL)

        XCTAssertNil(settings.selectedRemoteAsset)
        XCTAssertEqual(settings.recentItems.map(\.displayName), ["local", "远程跑动"])
    }

    func testRemoteRecentItemKeepsThumbnailAfterResetAndReloadsFrames() async throws {
        let galleryDirectory = rootDirectory.appendingPathComponent("GalleryRestore", isDirectory: true)
        let catalogURL = try makeRemoteGalleryCatalog(in: galleryDirectory, useArchive: false)
        let provider = MenuBarIconGalleryProvider(
            source: .localDevelopment(catalogURL)
        )
        let snapshot = try await provider.loadCatalog()
        let asset = try XCTUnwrap(snapshot.catalog.assets.first)
        let remoteStore = MenuBarIconRemoteAssetStore(
            rootDirectory: rootDirectory.appendingPathComponent("RemoteAssets", isDirectory: true)
        )
        let selection = try await remoteStore.installAsset(
            asset,
            contentBaseURL: snapshot.contentBaseURL,
            allowsFileResources: snapshot.allowsFileResources
        )
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory,
            remoteAssetStore: remoteStore
        )
        settings.useRemoteAsset(selection)
        let item = try XCTUnwrap(settings.recentItems.first)
        settings.resetToDefault()
        let resetItem = try XCTUnwrap(settings.recentItems.first)
        XCTAssertEqual(resetItem.displayName, "远程跑动")
        XCTAssertEqual(settings.previewImage(for: resetItem).size, NSSize(width: 18, height: 18))
        XCTAssertFalse(settings.isRemoteAssetCached(for: resetItem))

        let gallery = MenuBarIconGalleryLibrary(
            provider: provider,
            store: remoteStore,
            rootDirectory: rootDirectory.appendingPathComponent("RemoteAssets", isDirectory: true)
        )
        let didSelect = await gallery.selectRecentItem(item, iconSettings: settings)

        XCTAssertTrue(didSelect)
        XCTAssertEqual(settings.selectedRemoteAsset?.id, "remote-runner")
        XCTAssertTrue(settings.isRemoteAssetCached(for: try XCTUnwrap(settings.recentItems.first)))
        XCTAssertTrue(settings.imagePayload(for: NSAppearance(named: .aqua)).isAnimated)
    }

    func testOversizedAnimationIsRejectedBeforeDecoding() async throws {
        let url = rootDirectory.appendingPathComponent("too-large.gif")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0, count: MenuBarIconProcessing.maxAnimationFileSize + 1).write(to: url)
        let settings = MenuBarIconSettings(
            userDefaults: userDefaults,
            rootDirectory: rootDirectory
        )

        await settings.importAnimation(from: url, for: .light)

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertEqual(settings.lastErrorMessage, MenuBarIconImportError.animationTooLarge.userMessage)
    }

    func testBackgroundRemoverMakesCornerColoredPixelsTransparent() throws {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 16, height: 16)).fill()
        image.unlockFocus()

        let output = try XCTUnwrap(
            MenuBarIconBackgroundRemover.removingBackground(
                from: image,
                options: .default
            )
        )
        let cgImage = try XCTUnwrap(cgImage(from: output))
        let pixel = try XCTUnwrap(pixelRGBA(in: cgImage, x: 0, y: 0))

        XCTAssertLessThan(pixel.alpha, 32)
    }

    private func makeImageFile(name: String, color: NSColor) throws -> URL {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 48, height: 48)).fill()
        image.unlockFocus()

        let url = rootDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(MenuBarIconProcessing.pngData(from: image))
        try data.write(to: url)
        return url
    }

    private func makeImageFileWithBackground(name: String) throws -> URL {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 64)).fill()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: 16, width: 32, height: 32)).fill()
        image.unlockFocus()

        let url = rootDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(MenuBarIconProcessing.pngData(from: image))
        try data.write(to: url)
        return url
    }

    private func makeAnimatedGIFFile(name: String, frameDelay: Double = 0.12) throws -> URL {
        let url = rootDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            3,
            nil
        ) else {
            XCTFail("Could not create GIF destination")
            return url
        }

        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 0
                ]
            ] as CFDictionary
        )

        for color in [NSColor.systemRed, .systemGreen, .systemBlue] {
            let image = NSImage(size: NSSize(width: 32, height: 32))
            image.lockFocus()
            color.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
            image.unlockFocus()

            guard let cgImage = cgImage(from: image) else {
                XCTFail("Could not make GIF frame")
                return url
            }

            CGImageDestinationAddImage(
                destination,
                cgImage,
                [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: frameDelay
                    ]
                ] as CFDictionary
            )
        }

        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeMP4File(name: String) throws -> URL {
        let url = rootDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64
            ]
        )
        writer.add(input)

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for (index, color) in [NSColor.systemRed, .systemGreen, .systemBlue, .systemOrange].enumerated() {
            let buffer = try XCTUnwrap(makePixelBuffer(color: color))
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 6)))
        }

        input.markAsFinished()
        let finished = expectation(description: "MP4 writer finished")
        writer.finishWriting {
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func makeRemoteGalleryCatalog(in directory: URL, useArchive: Bool) throws -> URL {
        let assetDirectory = directory.appendingPathComponent("assets/remote-runner", isDirectory: true)
        let framesDirectory = assetDirectory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)

        for (index, color) in [NSColor.systemRed, .systemGreen, .systemBlue].enumerated() {
            let sourceURL = try makeImageFile(name: "remote-frame-\(index).png", color: color)
            let destinationURL = framesDirectory.appendingPathComponent(String(format: "frame-%03d.png", index))
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        try FileManager.default.copyItem(
            at: framesDirectory.appendingPathComponent("frame-000.png"),
            to: assetDirectory.appendingPathComponent("preview.png")
        )

        var asset: [String: Any] = [
            "id": "remote-runner",
            "title": "远程跑动",
            "categoryID": "featured",
            "version": "1",
            "previewPath": "assets/remote-runner/preview.png",
            "frameCount": 3,
            "frameDuration": 0.1
        ]

        if useArchive {
            let archiveURL = assetDirectory.appendingPathComponent("asset.zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [
                "-c",
                "-k",
                "--sequesterRsrc",
                "--rsrc",
                framesDirectory.path,
                archiveURL.path
            ]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            asset["archivePath"] = "assets/remote-runner/asset.zip"
            asset["archiveFramePathPattern"] = "frame-%03d.png"
        } else {
            asset["framePathPattern"] = "assets/remote-runner/frames/frame-%03d.png"
        }

        let catalog: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": "2026-05-20T00:00:00Z",
            "baseURL": directory.appendingPathComponent("", isDirectory: true).absoluteString,
            "categories": [
                [
                    "id": "featured",
                    "title": "精选"
                ]
            ],
            "assets": [asset]
        ]

        let catalogURL = directory.appendingPathComponent("catalog.dev.json")
        let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: catalogURL)
        return catalogURL
    }

    private func makePixelBuffer(color: NSColor) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32ARGB,
            nil,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
            let context = CGContext(
                data: baseAddress,
                width: 64,
                height: 64,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else {
            return nil
        }

        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return pixelBuffer
    }

    private func cgImage(from image: NSImage) -> CGImage? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private func pixelRGBA(in image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (red: pixel[0], green: pixel[1], blue: pixel[2], alpha: pixel[3])
    }
}
