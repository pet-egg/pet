import Foundation

/// 완전체 펫 수집 보너스. 완전체가 한 마리 늘 때마다 **다른** 펫들의 대전 스탯이 5% 오른다.
///
///   완전체 1마리 → +5%  ·  5마리 → +25%  ·  10마리 → +50%
///
/// 한 펫만 키우면 나머지는 대전에서 쓸모가 없다. 이 보너스는 여러 펫을 끝까지 키운
/// 보람을 아직 덜 자란 펫에게 나눠 준다 — 그래서 "다른" 펫에게만 준다.
enum CollectionBonus {
    /// 완전체 한 마리당 오르는 비율.
    static let perComplete: Double = 0.05
    /// 상한. 10마리에서 멈춘다 — 끝없이 오르면 새로 시작한 펫이 다 자란 펫을 이기게
    /// 되어 대전의 의미가 사라진다.
    static let cap: Double = 0.50

    /// 완전체인가 — 경험치가 마지막 진화 지점(`XPModel.maxTokens`)에 닿았는가.
    ///
    /// 진화가 없는 펫(메타몽·비숑 등)도 같은 기준이다. 진화 사용 토글과는 무관하다 —
    /// 토글은 보이는 모습을 정할 뿐 이룬 것을 지우지 않는다.
    static func isComplete(tokens: Double) -> Bool {
        tokens >= XPModel.maxTokens
    }

    /// `excluding` 을 뺀 완전체 수. 대전에 나간 펫 자신은 세지 않는다.
    static func completeCount(in tokens: [String: Double], excluding slug: String? = nil) -> Int {
        tokens.filter { $0.key != slug && isComplete(tokens: $0.value) }.count
    }

    /// 완전체 `count` 마리가 주는 보너스(0...cap).
    static func bonus(forCompleteCount count: Int) -> Double {
        min(cap, Double(max(0, count)) * perComplete)
    }

    /// 마우스 오버 이름 뒤에 붙는 별. 완전체 한 마리당 ⭐️ 하나.
    ///
    /// 별은 **가진 완전체 전체**를 센다 — 보너스와 달리 자기 자신도 포함한다. 보너스는
    /// "다른 펫에게 나눠 주는 것" 이라 자기를 빼지만, 별은 지금까지 몇 마리를 끝까지
    /// 키웠는지 보여 주는 배지다.
    ///
    /// 10개를 넘으면 `⭐️×13` 으로 줄인다. 펫이 36종까지 있어 다 늘어놓으면 문구가 화면을
    /// 가로지른다. 10 은 보너스 상한(+50%)과 같은 지점이다.
    static func stars(forCompleteCount count: Int) -> String {
        guard count > 0 else { return "" }
        return count <= starLimit ? String(repeating: "⭐️", count: count) : "⭐️×\(count)"
    }

    /// 별을 하나씩 늘어놓는 최대 개수.
    static let starLimit = 10

    /// 대전 파워에 보너스를 얹는다. 파워는 0...1 계약이라 1 을 넘지 않게 자른다.
    ///
    /// 파워 1.0 은 이미 갓 시작한 상대를 한 방에 눕히는 값이다. 그래서 다 자란 펫으로
    /// 나가면 보너스가 눈에 띄지 않는다 — 덜 자란 펫을 끌어올리는 보너스라 그게 맞다.
    static func apply(_ bonus: Double, to power: Double) -> Double {
        min(1, max(0, power) * (1 + bonus))
    }
}
