import SwiftUI
import AppKit
import ServiceManagement
import Observation
import UserNotifications

// MARK: - Theme (macOS 26+ Liquid Glass)

private extension Color {
    static let appAccent = Color(red: 205/255, green: 89/255, blue: 254/255) // #CD59FE
}

// MARK: - Notifications Helper

private enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Core Logic

@Observable @MainActor
final class VolumeManager {
    struct FileInfo: Identifiable, Hashable {
        let id = UUID()
        let url: URL
        let name: String
        let sizeText: String
    }

    struct Volume: Identifiable {
        let id = UUID()
        let url: URL
        var name: String
        var capacity: Int64
        var freeSpace: Int64
        var status: Status = .idle
        var isAnalyzing: Bool = false
        var blockingProcesses: [String] = []
        var topFiles: [FileInfo] = []

        enum Status: Equatable {
            case idle, cleaning, ejecting, success, busy, ejected, error(String)
        }

        var usedPercent: Double {
            guard capacity > 0 else { return 0 }
            return Double(capacity - freeSpace) / Double(capacity)
        }
    }

    var volumes: [Volume] = []
    var totalCleanedSize: Int64 = UserDefaults.standard.value(forKey: "totalCleanedSize") as? Int64 ?? 0
    var connectedCount: Int { volumes.count }

    private let exactJunk = [".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", "Thumbs.db"]
    private let junkPrefix = "._"

    private var analysisTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        Task { await refresh() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumeMounted), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumeUnmounted), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func volumeMounted() {
        Task { [weak self] in
            await self?.refresh()
            try? await Task.sleep(for: .seconds(1.5))
            await self?.refresh()
        }
    }

    @objc private func volumeUnmounted() {
        Task { [weak self] in await self?.refresh() }
    }

    private func cancelAllAnalysis() {
        for (_, task) in analysisTasks { task.cancel() }
        analysisTasks.removeAll()
    }

    func refresh() async {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey
        ]
        let hiddenPaths = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []
        let allPaths = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []
        ) ?? []
        var seen = Set<URL>()
        var paths: [URL] = []
        for url in hiddenPaths + allPaths {
            if seen.insert(url).inserted { paths.append(url) }
        }

        // Собираем URL'ы актуальных внешних томов
        var currentURLs: [URL] = []
        var urlResources: [URL: URLResourceValues] = [:]
        for url in paths {
            guard url.path != "/" else { continue }
            let inVolumes = url.path.hasPrefix("/Volumes/")
            guard inVolumes else { continue }
            let res = try? url.resourceValues(forKeys: Set(keys))
            let isRemovable = res?.volumeIsRemovable ?? false
            let isEjectable = res?.volumeIsEjectable ?? false
            if res?.volumeIsInternal == true && !isRemovable && !isEjectable { continue }
            let name = url.lastPathComponent
            if name.hasPrefix("com.apple.") { continue }
            currentURLs.append(url)
            if let res { urlResources[url] = res }
        }

        let currentURLSet = Set(currentURLs)
        let existingURLs = Set(volumes.map(\.url))

        // Удалённые тома — отменяем их анализ
        let removedURLs = existingURLs.subtracting(currentURLSet)
        for url in removedURLs {
            if let vol = volumes.first(where: { $0.url == url }) {
                analysisTasks[vol.id]?.cancel()
                analysisTasks.removeValue(forKey: vol.id)
            }
        }

        // Новые тома — которых раньше не было
        let addedURLs = currentURLSet.subtracting(existingURLs)

        // Обновляем существующие тома (capacity/freeSpace), сохраняя их id, status, topFiles
        var updatedVolumes: [Volume] = []
        for url in currentURLs {
            if let existing = volumes.first(where: { $0.url == url }) {
                let res = urlResources[url]
                var vol = existing
                vol.capacity = Int64(res?.volumeTotalCapacity ?? 0)
                vol.freeSpace = Int64(res?.volumeAvailableCapacity ?? 0)
                if let newName = res?.volumeName { vol.name = newName }
                updatedVolumes.append(vol)
            } else {
                let res = urlResources[url]
                updatedVolumes.append(Volume(
                    url: url,
                    name: res?.volumeName ?? url.lastPathComponent,
                    capacity: Int64(res?.volumeTotalCapacity ?? 0),
                    freeSpace: Int64(res?.volumeAvailableCapacity ?? 0)
                ))
            }
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            volumes = updatedVolumes
        }

        // Запускаем deep scan только для новых томов
        for vol in updatedVolumes where addedURLs.contains(vol.url) {
            let id = vol.id
            let task: Task<Void, Never> = Task { [weak self] in
                await self?.startSpaceAnalysis(for: id)
            }
            analysisTasks[id] = task
        }
    }

    private func startSpaceAnalysis(for id: UUID) async {
        guard let volume = volumes.first(where: { $0.id == id }) else { return }
        if let idx = volumes.firstIndex(where: { $0.id == id }) {
            volumes[idx].isAnalyzing = true
        }
        let url = volume.url
        let results = await Task.detached(priority: .background) {
            performDeepScan(at: url)
        }.value
        guard !Task.isCancelled else { return }
        if let idx = volumes.firstIndex(where: { $0.id == id }) {
            volumes[idx].topFiles = results
            volumes[idx].isAnalyzing = false
        }
        analysisTasks.removeValue(forKey: id)
    }

    func open(_ volume: Volume) {
        NSWorkspace.shared.open(volume.url)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Eject

    func eject(_ volume: Volume, force: Bool = false) {
        guard let index = volumes.firstIndex(where: { $0.id == volume.id }) else { return }
        withAnimation { volumes[index].status = .cleaning }

        Task {
            let url = volume.url
            let volId = volume.id
            let volName = volume.name
            let cleanedSize = await cleanVolumeInBackground(url)
            withAnimation {
                totalCleanedSize += cleanedSize
                persistCleanedSize()
                if let idx = volumes.firstIndex(where: { $0.id == volId }) {
                    volumes[idx].status = .ejecting
                }
            }

            let success: Bool
            if force {
                success = await forceUnmount(url)
            } else {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    success = true
                } catch {
                    success = false
                }
            }

            if success {
                withAnimation {
                    if let idx = volumes.firstIndex(where: { $0.id == volId }) {
                        volumes[idx].status = .ejected
                    }
                }
                NSSound(named: "Glass")?.play()
                Notifier.send(title: "Диск извлечён", body: "\(volName) безопасно отключён.")
                try? await Task.sleep(for: .seconds(1.2))
                await refresh()
            } else {
                let processes = await getBusyProcessesInBackground(for: url)
                withAnimation {
                    if let idx = volumes.firstIndex(where: { $0.id == volId }) {
                        volumes[idx].status = processes.isEmpty ? .error("Не удалось извлечь") : .busy
                        volumes[idx].blockingProcesses = processes
                    }
                }
                Notifier.send(
                    title: "Ошибка извлечения",
                    body: processes.isEmpty ? "\(volName): не удалось извлечь." : "\(volName) занят: \(processes.joined(separator: ", "))"
                )
            }
        }
    }

    func ejectAll() {
        let idle = volumes.filter { $0.status == .idle }
        for vol in idle { eject(vol) }
    }

    func retry(_ volume: Volume) {
        guard let idx = volumes.firstIndex(where: { $0.id == volume.id }) else { return }
        withAnimation { volumes[idx].status = .idle }
        volumes[idx].blockingProcesses = []
        eject(volumes[idx])
    }

    func forceEject(_ volume: Volume) {
        guard let idx = volumes.firstIndex(where: { $0.id == volume.id }) else { return }
        withAnimation { volumes[idx].status = .idle }
        volumes[idx].blockingProcesses = []
        eject(volumes[idx], force: true)
    }

    private func forceUnmount(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.launchPath = "/usr/sbin/diskutil"
            task.arguments = ["unmountDisk", "force", url.path]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            try? task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        }.value
    }

    // MARK: Busy processes (off main thread)

    private func getBusyProcessesInBackground(for url: URL) async -> [String] {
        let path = url.path
        return await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.launchPath = "/usr/sbin/lsof"
            task.arguments = ["-t", "+D", path]
            let pipe = Pipe()
            task.standardOutput = pipe
            try? task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [String]() }
            let pids = output.split(separator: "\n").map { String($0) }
            var names: Set<String> = []
            for pid in pids {
                let pt = Process()
                pt.launchPath = "/bin/ps"
                pt.arguments = ["-p", pid, "-o", "comm="]
                let p = Pipe()
                pt.standardOutput = p
                try? pt.run()
                pt.waitUntilExit()
                let d = p.fileHandleForReading.readDataToEndOfFile()
                if let n = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    names.insert((n as NSString).lastPathComponent)
                }
            }
            return Array(names).sorted()
        }.value
    }

    // MARK: Clean

    private func cleanVolumeInBackground(_ url: URL) async -> Int64 {
        let junkNames = exactJunk
        let prefix = junkPrefix
        return await Task.detached(priority: .userInitiated) {
            var freed: Int64 = 0
            let fm = FileManager.default

            for item in junkNames {
                let fullURL = url.appendingPathComponent(item)
                freed += itemSize(at: fullURL)
                try? fm.removeItem(at: fullURL)
            }

            let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [])
            while let fileURL = enumerator?.nextObject() as? URL {
                let name = fileURL.lastPathComponent
                if name.hasPrefix(prefix) {
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    try? fm.removeItem(at: fileURL)
                    freed += Int64(size)
                }
            }
            return freed
        }.value
    }

    private func persistCleanedSize() {
        UserDefaults.standard.set(totalCleanedSize, forKey: "totalCleanedSize")
    }
}

private func itemSize(at url: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    if isDir.boolValue {
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let fileUrl = enumerator?.nextObject() as? URL {
            total += Int64((try? fileUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    } else {
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

private func performDeepScan(at url: URL) -> [VolumeManager.FileInfo] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
    let startTime = Date()
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return [] }
    var topList: [(url: URL, size: Int64)] = []
    let skipDirs = [".Spotlight-V100", ".Trashes", ".fseventsd"]
    while let fileUrl = enumerator.nextObject() as? URL {
        if Date().timeIntervalSince(startTime) > 20.0 { break }
        if skipDirs.contains(fileUrl.lastPathComponent) {
            enumerator.skipDescendants()
            continue
        }
        guard let res = try? fileUrl.resourceValues(forKeys: Set(keys)),
              res.isDirectory == false,
              let size = res.fileSize else { continue }
        let s = Int64(size)
        if s < 1024 * 1024 { continue }
        if topList.count < 5 || s > (topList.last?.size ?? 0) {
            topList.append((url: fileUrl, size: s))
            topList.sort(by: { $0.size > $1.size })
            if topList.count > 5 { _ = topList.popLast() }
        }
    }
    let bcf = ByteCountFormatter()
    bcf.countStyle = .file
    return topList.map { VolumeManager.FileInfo(url: $0.url, name: $0.url.lastPathComponent, sizeText: bcf.string(fromByteCount: $0.size)) }
}

// MARK: - UI

@MainActor
struct MenuBarView: View {
    @State private var manager = VolumeManager()
    @Namespace private var glassNamespace
    @State private var powerHover = false
    @State private var ejectAllHover = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            header
            if manager.volumes.isEmpty {
                emptyState
            } else {
                volumesContent
                if manager.volumes.filter({ $0.status == .idle }).count > 1 {
                    ejectAllButton
                }
            }
            if manager.volumes.contains(where: { $0.status == .busy }) {
                Text("Подсказка: Full Disk Access улучшит определение процессов.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(Color.clear)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text("CleanEject")
                    .font(.system(size: 15, weight: .bold))
                Spacer(minLength: 8)
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(powerHover ? .red : .primary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.primary.opacity(powerHover ? 0.15 : 0.08)))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .onHover { powerHover = $0 }
            }

            HStack(spacing: 16) {
                Text("Очищено: \(formatBytes(manager.totalCleanedSize))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.appAccent.opacity(0.12))
                    .clipShape(Capsule())
                Toggle("Запуск при входе", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Color.appAccent)
                    .font(.system(size: 11))
                    .onChange(of: launchAtLogin) { _, value in
                        do {
                            if value { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var volumesContent: some View {
        let count = manager.volumes.count
        let useScroll = count > 3
        let content = VStack(spacing: 10) {
            ForEach(manager.volumes) { volume in
                VolumeRow(
                    volume: volume,
                    onOpen: { manager.open(volume) },
                    onEject: { manager.eject(volume) },
                    onRetry: { manager.retry(volume) },
                    onForceEject: { manager.forceEject(volume) },
                    onReveal: { manager.revealInFinder($0) }
                )
                .glassEffectID(volume.id, in: glassNamespace)
            }
        }
        .padding(.vertical, 2)

        if useScroll {
            ScrollView(.vertical, showsIndicators: true) {
                content
            }
            .frame(maxHeight: 450)
        } else {
            content
        }
    }

    private var ejectAllButton: some View {
        Button {
            manager.ejectAll()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "eject.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("Извлечь все")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(ejectAllHover ? Color.appAccent : .primary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12, style: .continuous))
        .onHover { ejectAllHover = $0 }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Нет внешних дисков")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 110)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
struct VolumeRow: View {
    let volume: VolumeManager.Volume
    let onOpen: () -> Void
    let onEject: () -> Void
    let onRetry: () -> Void
    let onForceEject: () -> Void
    let onReveal: (URL) -> Void

    @State private var hover = false
    @State private var ejectHover = false
    @State private var chartHover = false
    @State private var showTopFiles = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.appAccent.opacity(hover ? 0.25 : 0.15)))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(volume.name)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.primary)
                            if volume.isAnalyzing {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.6)
                            } else if !volume.topFiles.isEmpty {
                                Button { showTopFiles.toggle() } label: {
                                    Image(systemName: "chart.bar.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.appAccent.opacity(chartHover || showTopFiles ? 1.0 : 0.6))
                                        .frame(width: 24, height: 24)
                                        .background(Circle().fill(Color.appAccent.opacity(chartHover ? 0.15 : 0)))
                                }
                                .buttonStyle(.plain)
                                .scaleEffect(chartHover ? 1.1 : 1.0)
                                .onHover { chartHover = $0 }
                                .popover(isPresented: $showTopFiles, arrowEdge: .top) {
                                    TopFilesListView(files: volume.topFiles) { url in
                                        onReveal(url)
                                        showTopFiles = false
                                    }
                                }
                            }
                        }
                        statusInfo
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            actionButton
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
        .scaleEffect(hover ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.easeInOut(duration: 0.3), value: volume.status)
        .onHover { hover = $0 }
    }

    @ViewBuilder
    private var statusInfo: some View {
        if volume.status == .busy && !volume.blockingProcesses.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Занято: \(volume.blockingProcesses.joined(separator: ", "))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                HStack(spacing: 8) {
                    Button("Повторить") { onRetry() }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                    Button("Принудительно") { onForceEject() }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        } else if case .error(let msg) = volume.status {
            VStack(alignment: .leading, spacing: 2) {
                Text(msg.isEmpty ? "Ошибка извлечения" : msg)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button("Повторить") { onRetry() }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .buttonStyle(.plain)
            }
        } else {
            ProgressView(value: volume.usedPercent)
                .tint(volume.usedPercent > 0.8 ? .orange : Color.appAccent)
            Text(formatSize(volume))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if volume.status == .busy || (volume.status != .idle && volume.status != .cleaning && volume.status != .ejecting) {
            EmptyView()
        } else {
            Button(action: onEject) {
                statusIcon
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.primary.opacity(ejectHover ? 0.15 : 0.08)))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .onHover { ejectHover = $0 }
            .disabled(volume.status != .idle)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch volume.status {
        case .idle:
            Image(systemName: "eject.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ejectHover ? Color.appAccent : .secondary)
        case .cleaning, .ejecting:
            ProgressView()
                .controlSize(.small)
                .tint(.orange)
        case .busy:
            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange)
        case .ejected, .success:
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.red)
        }
    }

    private func formatSize(_ v: VolumeManager.Volume) -> String {
        let bcf = ByteCountFormatter()
        bcf.countStyle = .file
        return "\(bcf.string(fromByteCount: v.freeSpace)) свободно из \(bcf.string(fromByteCount: v.capacity))"
    }
}

struct TopFilesListView: View {
    let files: [VolumeManager.FileInfo]
    let onSelect: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Крупные файлы")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            ForEach(files) { file in
                FileRowView(file: file, onSelect: onSelect)
                if file.id != files.last?.id {
                    Divider()
                        .opacity(0.1)
                        .padding(.horizontal, 12)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 260)
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

struct FileRowView: View {
    let file: VolumeManager.FileInfo
    let onSelect: (URL) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect(file.url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                    Text(file.sizeText)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isHovered ? Color.appAccent : .secondary.opacity(0.4))
                    .scaleEffect(isHovered ? 1.1 : 1.0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - App Delegate

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestPermission()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "eject.circle.fill", accessibilityDescription: "CleanEject")
        button.action = #selector(togglePopover)
        button.target = self

        let controller = NSHostingController(rootView: MenuBarView())
        controller.sizingOptions = .preferredContentSize

        popover = NSPopover()
        popover?.contentViewController = controller
        popover?.behavior = .transient
        popover?.appearance = NSAppearance(named: .vibrantDark)

        updateBadge()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(badgeMountChanged), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(badgeMountChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc private func badgeMountChanged() {
        Task { @MainActor [weak self] in
            self?.updateBadge()
            try? await Task.sleep(for: .seconds(1.0))
            self?.updateBadge()
        }
    }

    func updateBadge() {
        guard let button = statusItem?.button else { return }
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let hiddenURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let allURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        var seen = Set<URL>()
        var urls: [URL] = []
        for url in hiddenURLs + allURLs {
            if seen.insert(url).inserted { urls.append(url) }
        }
        let count = urls.filter { url in
            guard url.path != "/" else { return false }
            guard url.path.hasPrefix("/Volumes/") else { return false }
            let name = url.lastPathComponent
            if name.hasPrefix("com.apple.") { return false }
            let res = try? url.resourceValues(forKeys: Set(keys))
            let isRemovable = res?.volumeIsRemovable ?? false
            let isEjectable = res?.volumeIsEjectable ?? false
            if res?.volumeIsInternal == true && !isRemovable && !isEjectable { return false }
            return true
        }.count

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        if count > 0 {
            button.image = NSImage(systemSymbolName: "eject.circle.fill", accessibilityDescription: "CleanEject \(count)")?.withSymbolConfiguration(config)
            button.title = " \(count)"
        } else {
            button.image = NSImage(systemSymbolName: "eject.circle", accessibilityDescription: "CleanEject")?.withSymbolConfiguration(config)
            button.title = ""
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            _ = popover.contentViewController?.view
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.makeKey()
                window.level = .statusBar
                if let frameView = window.contentView?.superview {
                    frameView.wantsLayer = true
                    if let bgView = frameView.subviews.first, type(of: bgView).description().contains("VisualEffect") {
                        bgView.isHidden = true
                    }
                }
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
