import Foundation
import Security

/// 밖에서 끝낸 일 하나 — GitHub PR 이나 Linear 티켓.
///
/// "퀘스트" 라고 부르는 이유: 토큰 경험치는 켜 두면 저절로 오르는 배경 성장인데,
/// 이쪽은 **내가 무언가를 끝냈을 때만** 들어온다. 성질이 달라서 같은 이름으로
/// 묶으면 어느 쪽이 오른 건지 구분이 안 된다.
struct Quest: Equatable {
    enum Source: String {
        case githubPR
        case linearIssue

        var badge: String {
            switch self {
            case .githubPR: return "PR"
            case .linearIssue: return "티켓"
            }
        }
    }

    /// 중복 지급을 막는 키. PR 은 `gh:owner/repo#21`, 티켓은 `linear:TECH-1375`.
    /// PR 을 닫았다 다시 열거나 티켓을 Done → 진행중 → Done 왕복해도 키가 같아서
    /// 경험치는 한 번만 들어간다.
    let id: String
    let source: Source
    /// 말풍선과 목록에 쓰는 짧은 이름. 예: `pet#21`, `TECH-1375`.
    let name: String
    let title: String
    let completedAt: Date
}

/// GitHub PR 과 Linear 티켓을 주기적으로 훑어, **새로** 끝난 것만 알려 준다.
///
/// 왜 폴링인가: 웹훅을 받으려면 이 맥북이 밖에서 접근 가능해야 하고 서버가 필요하다.
/// 개인 데스크톱 앱에 그걸 붙일 이유가 없다. 5분에 한 번 물어보면 충분하다.
///
/// GitHub 는 `gh` CLI 를 그대로 쓴다. 이미 로그인돼 있어서 이 앱이 토큰을 보관할
/// 필요가 없다 — 앱이 남의 자격증명을 들고 있지 않는 것이 가장 안전하다.
///
/// Linear 는 그런 CLI 가 없어서 GraphQL API 를 직접 부르고, 개인 API 키를 키체인
/// (암호를 안전하게 보관하는 macOS 기능)에서 읽는다. 키가 없으면 Linear 쪽만
/// 조용히 꺼진다 — GitHub 퀘스트는 그대로 돈다.
final class QuestService {
    /// 퀘스트 하나당 주는 경험치.
    static let rewardPerQuest: Double = 300_000
    /// 훑는 주기.
    static let pollInterval: TimeInterval = 5 * 60
    /// 얼마나 옛것까지 볼지. 이보다 오래된 것은 "새로 끝난 것" 일 수가 없다.
    private static let lookbackDays = 7

    /// 새로 끝난 퀘스트들. 메인 큐에서 불린다.
    var onQuests: (([Quest]) -> Void)?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "connor-pet.quests")
    private var polling = false
    /// 지급 기록을 어디에 쌓을지. 자체검증이 사용자의 실제 기록을 건드리지 않도록
    /// 별도 저장소를 넣을 수 있게 열어 뒀다.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        poll()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // .common 으로 넣는다. 기본 모드로만 걸면 메뉴가 열려 있거나 펫을 끄는 동안
        // 시계가 멈춘다 — 모션 해제 타이머에서 같은 문제를 겪었다.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    private func poll() {
        queue.async { [weak self] in
            guard let self, !self.polling else { return }
            self.polling = true
            defer { self.polling = false }

            let since = Date().addingTimeInterval(-Double(Self.lookbackDays) * 86_400)
            var found = self.fetchGitHubPRs(since: since)
            found += self.fetchLinearIssues(since: since)

            let fresh = self.creditNew(found)
            guard !fresh.isEmpty else { return }
            DispatchQueue.main.async { self.onQuests?(fresh) }
        }
    }

    // MARK: - 중복·최초 실행 처리

    private static let creditedKey = "questCreditedIDs"
    private static let baselineKey = "questBaselineTaken"
    /// 저장하는 id 개수 상한. 조회 창이 7일이라 그보다 넉넉하면 충분하다.
    private static let creditedCap = 2000

    /// 아직 경험치를 주지 않은 것만 골라 내고, 준 것으로 기록한다.
    ///
    /// **최초 실행은 경험치를 주지 않는다.** 처음 켰을 때 지난 7일치를 전부 지급하면
    /// 한 번에 수백만이 들어와 그날의 성장이 통째로 왜곡된다. 첫 실행은 지금까지의
    /// 것을 "이미 준 것" 으로만 적어 기준선을 만들고, 그 뒤에 새로 끝난 것부터 센다.
    /// 토큰 쪽 `accrualBaseline` 과 같은 방식이다.
    func creditNew(_ quests: [Quest]) -> [Quest] {
        var credited = Set(defaults.stringArray(forKey: Self.creditedKey) ?? [])
        let hadBaseline = defaults.bool(forKey: Self.baselineKey)

        let fresh = quests.filter { !credited.contains($0.id) }
        guard !fresh.isEmpty || !hadBaseline else { return [] }

        for quest in fresh { credited.insert(quest.id) }
        // 상한을 넘으면 절반을 버린다. 어느 것을 버릴지는 중요하지 않다 — 조회 창
        // 밖의 오래된 id 는 다시 나타나지 않는다.
        var stored = Array(credited)
        if stored.count > Self.creditedCap { stored = Array(stored.suffix(Self.creditedCap / 2)) }
        defaults.set(stored, forKey: Self.creditedKey)

        guard hadBaseline else {
            defaults.set(true, forKey: Self.baselineKey)
            questLog("최초 실행 — \(fresh.count)건을 기준선으로 기록(지급 없음)")
            return []
        }
        return fresh.sorted { $0.completedAt < $1.completedAt }
    }

    /// 기준선과 지급 기록을 지운다. "모든 경험치 초기화" 가 부른다 — 기록만 남으면
    /// 초기화 뒤에도 이미 끝낸 퀘스트가 다시 잡히지 않아 한참 조용해진다.
    static func resetHistory(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: creditedKey)
        defaults.removeObject(forKey: baselineKey)
    }

    // MARK: - GitHub

    /// `gh search prs` 로 내가 만든 PR 을 읽는다.
    ///
    /// 기준은 **생성**이다. 머지 기준이 "끝난 일" 에 더 가깝지만 리뷰가 늦게 붙으면
    /// 축하가 며칠 뒤에 오고, 그러면 퀘스트로 느껴지지 않는다. 취소(닫기) 처리를
    /// 따로 하지 않는 대신 id 로 한 번만 지급한다.
    func fetchGitHubPRs(since: Date) -> [Quest] {
        guard let gh = Self.executable(named: "gh", candidates: [
            "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
        ]) else {
            questLog("gh 를 찾지 못했다 — GitHub 퀘스트는 꺼진다")
            return []
        }

        let day = Self.dayFormatter.string(from: since)
        let args = ["search", "prs", "--author", "@me", "--created", ">=\(day)",
                    "--json", "number,title,createdAt,repository", "--limit", "100"]
        guard let data = Self.run(gh, args) else { return [] }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            questLog("gh 응답을 읽지 못했다: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
            return []
        }

        var quests: [Quest] = []
        for row in rows {
            guard
                let number = row["number"] as? Int,
                let stamp = row["createdAt"] as? String,
                let at = Self.parseISO(stamp),
                at >= since
            else { continue }
            let repo = (row["repository"] as? [String: Any])?["nameWithOwner"] as? String
            let short = repo?.split(separator: "/").last.map(String.init) ?? "?"
            quests.append(Quest(
                id: "gh:\(repo ?? short)#\(number)",
                source: .githubPR,
                name: "\(short)#\(number)",
                title: row["title"] as? String ?? "",
                completedAt: at
            ))
        }
        return quests
    }

    // MARK: - Linear

    /// Linear GraphQL API 로 내가 담당한 완료 티켓을 읽는다.
    ///
    /// 키가 없으면 조용히 빈 배열이다. 팀원마다 키를 발급해야 하므로, 안 넣은
    /// 사람에게 오류를 띄우는 것은 소용이 없다 — 메뉴에서 안내만 한다.
    func fetchLinearIssues(since: Date) -> [Quest] {
        guard let key = Self.linearAPIKey() else { return [] }

        let iso = Self.isoFormatter.string(from: since)
        let query = """
        query {
          viewer {
            assignedIssues(first: 100, filter: { completedAt: { gt: "\(iso)" } }) {
              nodes { identifier title completedAt }
            }
          }
        }
        """
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": query]) else { return [] }

        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 20

        // 폴링은 이미 전용 큐에서 돌고 있어 여기서 기다려도 UI 를 막지 않는다.
        var payload: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { questLog("Linear 요청 실패: \(error.localizedDescription)") }
            payload = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)

        guard
            let payload,
            let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        else { return [] }

        if let errors = object["errors"] {
            questLog("Linear 응답 오류: \(errors)")
            return []
        }
        guard
            let data = object["data"] as? [String: Any],
            let viewer = data["viewer"] as? [String: Any],
            let assigned = viewer["assignedIssues"] as? [String: Any],
            let nodes = assigned["nodes"] as? [[String: Any]]
        else { return [] }

        var quests: [Quest] = []
        for node in nodes {
            guard
                let identifier = node["identifier"] as? String,
                let stamp = node["completedAt"] as? String,
                let at = Self.parseISO(stamp),
                at >= since
            else { continue }
            quests.append(Quest(
                id: "linear:\(identifier)",
                source: .linearIssue,
                name: identifier,
                title: node["title"] as? String ?? "",
                completedAt: at
            ))
        }
        return quests
    }

    /// 키체인에 든 Linear 개인 API 키. 보관·읽기 규칙은 `LinearKeychain` 참고.
    static func linearAPIKey() -> String? { LinearKeychain.read() }

    /// 키가 실제로 통하는지 확인한다. 설정 창의 "저장하고 확인" 이 부른다 — 저장만
    /// 하고 끝내면 오타가 난 키도 저장됐다고 보이고, 5분 뒤 조용히 아무것도 안 잡힌다.
    ///
    /// 이슈를 부르지 않고 `viewer` 만 묻는다. 키가 맞는지만 보면 되고, 그쪽이 빠르다.
    static func verifyLinearKey(_ key: String, completion: @escaping (Result<String, Error>) -> Void) {
        let query = #"{"query":"query { viewer { name organization { name } } }"}"#
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.httpBody = query.data(using: .utf8)
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { data, _, error in
            let finish: (Result<String, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error { finish(.failure(error)); return }
            guard let data,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { finish(.failure(LinearKeyError.badResponse)); return }

            // Linear 는 키가 틀려도 HTTP 200 에 errors 를 담아 보낸다. 상태 코드만
            // 보면 잘못된 키를 통과시킨다.
            if let errors = object["errors"] as? [[String: Any]] {
                let message = errors.compactMap { $0["message"] as? String }.first
                finish(.failure(LinearKeyError.rejected(message ?? "키가 거부됐어요")))
                return
            }
            guard let payload = object["data"] as? [String: Any],
                  let viewer = payload["viewer"] as? [String: Any],
                  let name = viewer["name"] as? String
            else { finish(.failure(LinearKeyError.badResponse)); return }
            let org = (viewer["organization"] as? [String: Any])?["name"] as? String
            finish(.success(org.map { "\(name) · \($0)" } ?? name))
        }.resume()
    }

    enum LinearKeyError: LocalizedError {
        case badResponse
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .badResponse: return "Linear 응답을 읽지 못했어요"
            case .rejected(let message): return message
            }
        }
    }

    // MARK: - Helpers

    /// GUI 앱은 셸의 PATH 를 물려받지 못한다. 흔한 설치 위치를 직접 뒤진다 —
    /// 요약기가 `claude` 를 찾는 방식과 같다.
    private static func executable(named name: String, candidates: [String]) -> URL? {
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/\(name)")
        return fm.isExecutableFile(atPath: home.path) ? home : nil
    }

    private static func run(_ executable: URL, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return process.terminationStatus == 0 ? data : nil
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseISO(_ raw: String) -> Date? {
        isoWithFraction.date(from: raw) ?? isoFormatter.date(from: raw)
    }
}

func questLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["CONNORPET_DEBUG"] != nil else { return }
    FileHandle.standardError.write("[connor-pet] quest: \(message)\n".data(using: .utf8)!)
}
