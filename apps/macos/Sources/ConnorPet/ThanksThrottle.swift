import Foundation

/// 경험치를 받은 것에 대해 언제 고맙다고 말할지 정한다.
///
/// 상태 감시는 0.25초마다 도는데 그때마다 인사하면 말풍선이 끊이지 않는다. 그렇다고
/// 한 번 오른 뒤 조용하면 얼마나 받았는지가 안 보인다. 그래서 **모아 뒀다가 정해진
/// 간격마다 한 번** "이만큼 받았다" 고 말한다.
///
/// 타이머를 두지 않고 값을 넣을 때마다 판단하는 이유: 시각을 밖에서 넣으면 검증이
/// 5분을 실제로 기다리지 않아도 된다.
struct ThanksThrottle {
    /// 인사 사이 최소 간격.
    static let interval: TimeInterval = 5 * 60

    private var pending: Double = 0
    private var lastAt: Date?

    /// 새로 쌓인 경험치를 넣는다. 인사할 때가 됐으면 그동안 모인 양을 돌려준다.
    ///
    /// 첫 호출은 인사하지 않고 시계만 맞춘다 — 앱을 띄우자마자 인사부터 하면 무엇에
    /// 대한 인사인지 알 수 없다. 첫 창은 실행 시점부터 센다.
    mutating func add(_ tokens: Double, now: Date) -> Double? {
        if tokens > 0 { pending += tokens }
        guard let last = lastAt else {
            lastAt = now
            return nil
        }
        guard now.timeIntervalSince(last) >= Self.interval, pending >= 1 else { return nil }
        let total = pending
        pending = 0
        lastAt = now
        return total
    }
}
