import Foundation
import VCCore

/// ACP（Agent Client Protocol）の接続の失敗。
enum ACPError: Error, Equatable, CustomStringConvertible {
    /// 起動できない・初期化に失敗した（この方式は、使えない：従来の方式へ、戻れる）。
    case unavailable(String)
    /// 相手が、エラーを返した。
    case remote(code: Int, message: String)
    /// 接続が、閉じた（相手が、終わった）。
    case closed
    case timedOut

    var description: String {
        switch self {
        case let .unavailable(why): return why
        case let .remote(code, message): return tr("\(message)（\(code)）")
        case .closed: return tr("エージェントとの接続が、閉じました")
        case .timedOut: return tr("エージェントが、時間内に応えませんでした")
        }
    }
}

/// ACP の接続：エージェントを、**標準入出力で話す子プロセス**として起動し、JSON-RPC 2.0（1 行 1 メッセージ）で話す。
/// 要求（`request`）の応答を待つ・通知（`notify`）を送る・**相手からの要求**（許可の確認）に答える（`onRequest`）・相手からの通知（`onNotification`）を受ける。
/// 相手が終わったら、待っている要求は、すべて `closed` で終わる。シェルは使わない。
final class ACPConnection: @unchecked Sendable {
    /// `initialize` で名乗る、こちらの情報。**`version` は、ACP の仕様で必須**（`grok` は、無いと、`Invalid params` で断る：実測）。
    static var clientInfo: JSONValue {
        .object(["name": .string("voice-control"), "title": .string("voice-control"), "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")])
    }

    typealias RequestHandler = @Sendable (_ method: String, _ params: JSONValue) async -> JSONValue?
    typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue) -> Void

    private let argv: [String]
    private let directory: URL
    private let environment: [String: String]
    /// 相手の言葉を、ACP に訳す（ACP を話さない相手：`PiRPCDialect`）。なければ、そのまま。
    private let dialect: ACPWireDialect?
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Result<JSONValue, ACPError>, Never>] = [:]
    private var buffer = Data()
    private var closed = false
    private var requestHandler: RequestHandler?
    private var notificationHandler: NotificationHandler?

    // 終わるとき（`exit`）に、起動した子プロセスを、残さない：エージェントは、標準入力が閉じても、終わらない（実測：`vc chat` が終わっても、`agy acp` が残った）。
    private static let live = LiveConnections()
    private final class LiveConnections: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [ObjectIdentifier: Process] = [:]
        private var installed = false
        func add(_ process: Process) {
            lock.withLock {
                processes[ObjectIdentifier(process)] = process
                if !installed { installed = true; atexit { ACPConnection.live.terminateAll() } }
            }
        }
        func remove(_ process: Process) { lock.withLock { _ = processes.removeValue(forKey: ObjectIdentifier(process)) } }
        func terminateAll() {
            let all = lock.withLock { Array(processes.values) }
            for process in all where process.isRunning { ProcessTree.terminateAndWait(process) }   // 子孫ごと。終了の最中なので、待って止める
        }
    }

    init(argv: [String], directory: URL, environment: [String: String] = [:], dialect: ACPWireDialect? = nil) {
        self.argv = argv; self.directory = directory; self.environment = environment; self.dialect = dialect
    }

    deinit { close() }

    func setHandlers(onRequest: RequestHandler?, onNotification: NotificationHandler?) {
        lock.lock(); requestHandler = onRequest; notificationHandler = onNotification; lock.unlock()
    }

    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return !closed && (process?.isRunning ?? false) }

    /// 子プロセスを起動する。起動できなければ、`unavailable`。
    func start() throws {
        signal(SIGPIPE, SIG_IGN)   // 相手が終わったあとの書き込みで、こちらが終わらないように（書き込みの失敗として、扱う）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        env["PWD"] = directory.path
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; self?.finish(); return }
            self?.receive(data)
        }
        process.terminationHandler = { [weak self] _ in self?.finish() }
        do { try process.run() } catch { throw ACPError.unavailable(tr("起動できません（\(error.localizedDescription)）")) }
        lock.lock(); self.process = process; self.input = stdin.fileHandleForWriting; lock.unlock()
        Self.live.add(process)
    }

    /// 要求を送って、応答を待つ（`timeout` 秒まで）。
    func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = 120) async throws -> JSONValue {
        let id: Int = {
            lock.lock(); defer { lock.unlock() }
            nextID += 1
            return nextID
        }()
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.resolve(id: id, .failure(.timedOut))
        }
        defer { timer.cancel() }
        let result: Result<JSONValue, ACPError> = await withCheckedContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(returning: .failure(.closed)); return }
            pending[id] = continuation
            lock.unlock()
            write(["jsonrpc": JSONValue.string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
        }
        return try result.get()
    }

    /// 通知を送る（応答は、ない）。
    func notify(_ method: String, _ params: JSONValue) {
        write(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
    }

    /// 終える（子プロセスを、止める）。
    func close() {
        lock.lock()
        let process = self.process, input = self.input
        closed = true
        lock.unlock()
        try? input?.close()
        if let process {
            if process.isRunning { ProcessTree.terminate(process) }   // エージェントが起こした子孫（bash・osascript など）ごと
            Self.live.remove(process)
        }
        finish()
    }

    // MARK: 受信

    private func receive(_ data: Data) {
        var lines: [Data] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let message = JSONValue.parse(line) else { continue }   // JSON でない行（ログなど）は、読み飛ばす
            guard let dialect else { dispatch(message); continue }
            let translated = dialect.incoming(message)
            for line in translated.lines { writeRaw(line) }
            for message in translated.messages { dispatch(message) }
        }
    }

    private func dispatch(_ message: JSONValue) {
        let method = message["method"]?.string
        let idValue = message["id"]
        if let method {
            if let idValue {
                // 相手からの要求：許可の確認など。応答を、返す
                lock.lock(); let handler = requestHandler; lock.unlock()
                Task { [weak self] in
                    let result = await handler?(method, message["params"] ?? .null)
                    if let result { self?.write(["jsonrpc": .string("2.0"), "id": idValue, "result": result]) }
                    else { self?.write(["jsonrpc": .string("2.0"), "id": idValue, "error": .object(["code": .number(-32601), "message": .string("method not found: \(method)")])]) }
                }
            } else {
                lock.lock(); let handler = notificationHandler; lock.unlock()
                handler?(method, message["params"] ?? .null)
            }
        } else if let id = idValue?.int {
            if let error = message["error"] {
                resolve(id: id, .failure(.remote(code: error["code"]?.int ?? 0, message: error["message"]?.string ?? tr("エラー"))))
            } else {
                resolve(id: id, .success(message["result"] ?? .null))
            }
        }
    }

    private func resolve(id: Int, _ result: Result<JSONValue, ACPError>) {
        lock.lock(); let continuation = pending.removeValue(forKey: id); lock.unlock()
        continuation?.resume(returning: result)
    }

    /// 終わった：待っている要求を、すべて、`closed` で終える。
    private func finish() {
        lock.lock()
        closed = true
        let all = pending
        pending = [:]
        lock.unlock()
        for (_, continuation) in all { continuation.resume(returning: .failure(.closed)) }
    }

    private func write(_ object: [String: JSONValue]) {
        guard let dialect else { writeRaw(.object(object)); return }
        let translated = dialect.outgoing(.object(object))
        for line in translated.lines { writeRaw(line) }
        for message in translated.messages { dispatch(message) }   // 相手に聞かずに、すぐ返せるもの（要求は、すでに、待ちに入っている）
    }

    private func writeRaw(_ value: JSONValue) {
        guard var data = value.serialized() else { return }
        data.append(0x0A)
        lock.lock(); let input = self.input; let isClosed = closed; lock.unlock()
        guard !isClosed else { return }
        try? input?.write(contentsOf: data)   // try?: 相手が終わっていたら、書けない（応答を待つ側が、`closed` で終わる）
    }
}
