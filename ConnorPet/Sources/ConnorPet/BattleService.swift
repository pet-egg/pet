import Foundation
import Network

/// A peer discovered on the local network — another running copy of this app,
/// advertising itself via Bonjour. `id` is that instance's process-unique UUID
/// (so we can filter ourselves out and de-dupe), `name`/`pet` come from its TXT
/// record for display, and `endpoint` is what we dial to challenge it.
struct BattlePeer: Equatable {
    let id: String
    let name: String
    let pet: String
    let endpoint: NWEndpoint

    static func == (lhs: BattlePeer, rhs: BattlePeer) -> Bool { lhs.id == rhs.id }
}

/// Wire protocol between two apps. One flat Codable envelope keeps framing
/// trivial; unused fields stay nil per message kind.
///
///   challenger →  challenge {fromID, fromName, fromPet, power}
///   accepter   →  accept {fromID, fromName, fromPet, power, seed}  (accepter picks the seed)
///                 or decline {}
///   누구든    →  stare {fromID, fromName, fromPet}   (노려보기 — 응답 없음)
///
/// `power` 를 서로 실어 보내는 이유: 전투 계산에 양쪽의 성장 상태가 들어가는데,
/// 시드만으로는 상대의 파워를 알 수 없어 두 기기의 계산이 갈린다. challenge 와
/// accept 각각에 자기 파워를 담으면 그 시점에 양쪽 모두 두 값을 갖게 된다.
///
/// 그 뒤로는 추가 통신이 없다 — 같은 시드와 같은 파워로 각자 simulateBattle 을
/// 돌려 동일한 결과를 재생한다.
struct BattleMessage: Codable {
    enum Kind: String, Codable {
        case challenge
        case accept
        case decline
        case stare
    }
    let type: Kind
    var fromID: String?
    var fromName: String?
    var fromPet: String?
    var seed: UInt64?
    /// 보내는 쪽 펫의 성장 파워(0...1). 예전 버전과 주고받으면 nil 이라 0 으로 본다.
    var power: Double?
}

/// The Bonjour service type every copy of this app advertises and browses for.
/// (Must be ≤15 chars, letters/digits/hyphen — "connorpet" fits.)
let battleServiceType = "_connorpet._tcp"

/// Discovers other running apps on the same Wi-Fi and runs the challenge/accept
/// handshake that leads into a battle. Pure networking + protocol; it knows
/// nothing about windows or sprites — callers wire the callbacks to UI.
///
/// Lifecycle: `start()` brings up an `NWListener` (advertising us + accepting
/// inbound challenges) and an `NWBrowser` (finding peers). Everything runs on a
/// private serial queue; all callbacks are hopped to the main queue so the UI
/// layer never has to think about threading.
final class BattleService {
    /// This process's unique id — advertised in our TXT record, used by peers
    /// (and us) to recognize and filter self.
    let instanceID = UUID().uuidString
    /// Human label shown in others' peer lists (defaults to the computer name).
    let displayName: String
    /// Currently-selected pet slug; advertised so the opponent can render our
    /// actual character. Updated live via `updatePet(_:)`.
    private(set) var petSlug: String

    /// Fires (on main) whenever the discovered-peer set changes.
    var onPeersChanged: (([BattlePeer]) -> Void)?
    /// Fires (on main) when someone challenges us. Call `respond(true)` to accept
    /// (starts the battle) or `respond(false)` to decline.
    var onIncomingChallenge: ((_ fromName: String, _ respond: @escaping (Bool) -> Void) -> Void)?
    /// Fires (on main) when a battle is agreed (either we accepted an incoming
    /// challenge, or a peer accepted ours). Carries everything the UI needs to
    /// animate: our fixed role, the shared outcome, and the opponent's pet slug.
    var onBattleStart: ((_ myRole: BattleRole, _ outcome: BattleOutcome, _ opponentName: String, _ opponentPet: String) -> Void)?
    /// 누가 노려봤을 때. (보낸 사람 이름, 그쪽 펫 slug)
    var onStare: ((_ fromName: String, _ fromPet: String) -> Void)?
    /// 내 펫의 현재 파워(0...1)를 묻는다. 전투 계산에 실어 보낸다.
    var localPower: (() -> Double)?

    private let queue = DispatchQueue(label: "connorpet.battle")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [String: BattlePeer] = [:]

    /// Connections we've dialed out on, keyed by the peer id we challenged, held
    /// so ARC doesn't tear them down mid-handshake.
    private var outgoing: [String: BattleConnection] = [:]
    /// Inbound connections we've accepted, held until their handshake resolves.
    private var incoming: Set<BattleConnection> = []

    init(displayName: String? = nil, petSlug: String) {
        self.displayName = displayName ?? (Host.current().localizedName ?? "someone")
        self.petSlug = petSlug
    }

    /// Update the advertised pet after the user switches characters in the menu.
    /// Re-publishes the TXT record so peers see the new slug.
    func updatePet(_ slug: String) {
        queue.async {
            guard slug != self.petSlug else { return }
            self.petSlug = slug
            self.listener?.service = self.makeService()
        }
    }

    // MARK: - Lifecycle

    func start() {
        queue.async {
            self.startListener()
            self.startBrowser()
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            self.browser?.cancel(); self.browser = nil
            self.outgoing.values.forEach { $0.cancel() }
            self.incoming.forEach { $0.cancel() }
            self.outgoing.removeAll()
            self.incoming.removeAll()
        }
    }

    private func makeService() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = instanceID
        txt["name"] = displayName
        txt["pet"] = petSlug
        // Use the instance UUID as the Bonjour instance name so two copies on
        // the same Mac never collide / get auto-renamed.
        return NWListener.Service(name: instanceID, type: battleServiceType, txtRecord: txt)
    }

    // MARK: - Listener (advertise + accept inbound challenges)

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = makeService()
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleInbound(conn)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    battleLog("listener failed: \(err)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            battleLog("listener setup failed: \(error)")
        }
    }

    private func handleInbound(_ nwConn: NWConnection) {
        let conn = BattleConnection(connection: nwConn, queue: queue)
        incoming.insert(conn)
        conn.onMessage = { [weak self, weak conn] msg in
            guard let self, let conn else { return }
            self.handleInboundMessage(msg, on: conn)
        }
        conn.onClose = { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.queue.async { self.incoming.remove(conn) }
        }
        conn.start()
    }

    private func handleInboundMessage(_ msg: BattleMessage, on conn: BattleConnection) {
        // 노려보기는 응답이 없다. 알림만 띄우고 연결을 닫는다.
        if msg.type == .stare {
            let name = msg.fromName ?? "누군가"
            let pet = msg.fromPet ?? ""
            DispatchQueue.main.async { self.onStare?(name, pet) }
            queue.asyncAfter(deadline: .now() + 0.3) { conn.cancel() }
            return
        }
        guard msg.type == .challenge,
              let fromName = msg.fromName,
              let fromPet = msg.fromPet else { return }
        let challengerPower = msg.power ?? 0

        // Ask the UI (main thread) whether to accept; respond back on our queue.
        DispatchQueue.main.async {
            let respond: (Bool) -> Void = { accepted in
                self.queue.async {
                    guard accepted else {
                        conn.send(BattleMessage(type: .decline))
                        // Give the decline a moment to flush, then drop it.
                        self.queue.asyncAfter(deadline: .now() + 0.3) { conn.cancel() }
                        return
                    }
                    let seed = UInt64.random(in: UInt64.min...UInt64.max)
                    let myPower = self.localPower?() ?? 0
                    conn.send(BattleMessage(type: .accept,
                                            fromID: self.instanceID,
                                            fromName: self.displayName,
                                            fromPet: self.petSlug,
                                            seed: seed,
                                            power: myPower))
                    // We're the accepter; opponent is the challenger.
                    let outcome = simulateBattle(seed: seed,
                                                 powers: [.challenger: challengerPower,
                                                          .accepter: myPower])
                    DispatchQueue.main.async {
                        self.onBattleStart?(.accepter, outcome, fromName, fromPet)
                    }
                    // Keep the connection alive briefly so the accept flushes,
                    // then let it close — the battle itself needs no more traffic.
                    self.queue.asyncAfter(deadline: .now() + 1.0) { conn.cancel() }
                }
            }
            self.onIncomingChallenge?(fromName, respond)
        }
    }

    // MARK: - Browser (discover peers)

    private func startBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: battleServiceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.updatePeers(from: results)
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                battleLog("browser failed: \(err)")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func updatePeers(from results: Set<NWBrowser.Result>) {
        var next: [String: BattlePeer] = [:]
        for result in results {
            guard case let .bonjour(txt) = result.metadata,
                  let id = txt["id"], id != instanceID,   // skip ourselves
                  let name = txt["name"],
                  let pet = txt["pet"] else { continue }
            next[id] = BattlePeer(id: id, name: name, pet: pet, endpoint: result.endpoint)
        }
        peers = next
        let list = Array(next.values).sorted { $0.name < $1.name }
        DispatchQueue.main.async { self.onPeersChanged?(list) }
    }

    // MARK: - Outbound (노려보기)

    /// `peer` 를 노려본다. 응답을 기다리지 않는다 — 보내고 잠시 뒤 연결을 닫는다.
    /// 상대 쪽에서는 확인 버튼 하나짜리 알림이 뜬다.
    func stare(at peer: BattlePeer) {
        queue.async {
            let nwConn = NWConnection(to: peer.endpoint, using: .tcp)
            let conn = BattleConnection(connection: nwConn, queue: self.queue)
            conn.onReady = { [weak conn] in
                conn?.send(BattleMessage(type: .stare,
                                         fromID: self.instanceID,
                                         fromName: self.displayName,
                                         fromPet: self.petSlug))
                // 보낸 뒤 플러시될 시간만 주고 닫는다.
                self.queue.asyncAfter(deadline: .now() + 0.5) { conn?.cancel() }
            }
            conn.start()
        }
    }

    // MARK: - Outbound (challenge a peer)

    /// Challenge `peer`. Dials a fresh connection, sends our challenge, and waits
    /// for `accept` (→ `onBattleStart`) or `decline`. `onResult` reports the
    /// terminal outcome so the UI can show "declined"/"no answer".
    func challenge(_ peer: BattlePeer, onResult: @escaping (ChallengeResult) -> Void) {
        queue.async {
            let nwConn = NWConnection(to: peer.endpoint, using: .tcp)
            let conn = BattleConnection(connection: nwConn, queue: self.queue)
            self.outgoing[peer.id] = conn

            var settled = false
            let finish: (ChallengeResult) -> Void = { result in
                guard !settled else { return }
                settled = true
                DispatchQueue.main.async { onResult(result) }
                self.queue.asyncAfter(deadline: .now() + 0.3) {
                    conn.cancel()
                    self.outgoing[peer.id] = nil
                }
            }

            let myPower = self.localPower?() ?? 0
            conn.onReady = { [weak conn] in
                conn?.send(BattleMessage(type: .challenge,
                                         fromID: self.instanceID,
                                         fromName: self.displayName,
                                         fromPet: self.petSlug,
                                         power: myPower))
            }
            conn.onMessage = { msg in
                switch msg.type {
                case .accept:
                    guard let seed = msg.seed else { finish(.failed); return }
                    // We're the challenger; opponent is the accepter.
                    let outcome = simulateBattle(seed: seed,
                                                 powers: [.challenger: myPower,
                                                          .accepter: msg.power ?? 0])
                    DispatchQueue.main.async {
                        self.onBattleStart?(.challenger, outcome,
                                            msg.fromName ?? peer.name,
                                            msg.fromPet ?? peer.pet)
                    }
                    finish(.accepted)
                case .decline:
                    finish(.declined)
                case .challenge, .stare:
                    break // not expected inbound on the dialing side
                }
            }
            conn.onClose = { finish(.failed) }
            conn.start()

            // No answer in time → treat as failure so the UI doesn't hang.
            self.queue.asyncAfter(deadline: .now() + 15) { finish(.failed) }
        }
    }

    enum ChallengeResult {
        case accepted
        case declined
        case failed
    }
}

/// Length-prefixed JSON framing over a single `NWConnection`. Every message is
/// a 4-byte big-endian length followed by that many bytes of JSON. Handles both
/// directions the same way, so inbound (from the listener) and outbound (dialed)
/// connections share one implementation.
final class BattleConnection: Hashable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()

    var onReady: (() -> Void)?
    var onMessage: ((BattleMessage) -> Void)?
    var onClose: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onReady?()
                self?.receiveNext()
            case .failed, .cancelled:
                self?.onClose?()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: BattleMessage) {
        guard let payload = try? JSONEncoder().encode(message) else { return }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainFrames()
            }
            if isComplete || error != nil {
                self.onClose?()
                return
            }
            self.receiveNext()
        }
    }

    /// Pull every complete `[len][payload]` frame out of the buffer.
    private func drainFrames() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            let payload = buffer.subdata(in: 4..<total)
            buffer.removeSubrange(0..<total)
            if let message = try? JSONDecoder().decode(BattleMessage.self, from: payload) {
                onMessage?(message)
            }
        }
    }

    static func == (lhs: BattleConnection, rhs: BattleConnection) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

func battleLog(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil {
        FileHandle.standardError.write("[connor-pet][battle] \(message())\n".data(using: .utf8)!)
    }
}
