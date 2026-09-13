import Foundation

/// 대전 전적. 이 맥에만 쌓인다 — 상대와 주고받지 않는다.
///
/// 서로 보고하게 만들면 한쪽이 거짓을 보낼 수 있고, 그것을 막으려면 심판이 필요하다.
/// 개인 데스크톱 앱에 그런 것을 둘 이유가 없다. 각자 자기가 본 결과만 적는다 —
/// 어차피 두 기기가 같은 결과를 받는다(받는 쪽이 계산해 보내므로).
struct BattleRecord: Equatable {
    var wins: Int
    var losses: Int

    var total: Int { wins + losses }

    /// 승률(0...1). 한 판도 안 했으면 nil — 0% 로 보여 주면 "다 졌다" 로 읽힌다.
    var winRate: Double? {
        guard total > 0 else { return nil }
        return Double(wins) / Double(total)
    }

    /// 사람이 읽을 한 줄. "12승 8패 · 승률 60%"
    var summary: String {
        guard let rate = winRate else { return "아직 대전 기록이 없어요" }
        return "\(wins)승 \(losses)패 · 승률 \(Int((rate * 100).rounded()))%"
    }
}

extension BattleRecord {
    /// 이겼을 때 주는 경험치.
    static let winReward: Double = 500_000

    private static let winsKey = "battleWins"
    private static let lossesKey = "battleLosses"

    static func load(from defaults: UserDefaults = .standard) -> BattleRecord {
        BattleRecord(wins: defaults.integer(forKey: winsKey),
                     losses: defaults.integer(forKey: lossesKey))
    }

    /// 한 판의 결과를 더하고 갱신된 전적을 돌려준다.
    @discardableResult
    static func record(won: Bool, in defaults: UserDefaults = .standard) -> BattleRecord {
        var record = load(from: defaults)
        if won { record.wins += 1 } else { record.losses += 1 }
        defaults.set(record.wins, forKey: winsKey)
        defaults.set(record.losses, forKey: lossesKey)
        return record
    }

    /// 전적을 지운다. "모든 경험치 초기화" 가 함께 부른다 — 대전으로 얻은 경험치도
    /// 사라지는데 전적만 남으면 앞뒤가 안 맞는다.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: winsKey)
        defaults.removeObject(forKey: lossesKey)
    }
}
