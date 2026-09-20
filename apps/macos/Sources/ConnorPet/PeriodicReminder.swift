import Foundation

/// 정해진 간격마다 한 번만 참을 돌려주는 시계.
///
/// 상태 감시가 0.25초마다 도는 자리에서 "가끔 한 번" 을 만들 때 쓴다. 타이머를 두지
/// 않고 물어볼 때마다 시각으로 판단하므로, 검증이 실제 간격을 기다리지 않아도 된다.
struct PeriodicReminder {
    let interval: TimeInterval
    private var lastAt: Date?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// 지금 할 때인가. 첫 호출은 하지 않고 시계만 맞춘다 — 앱을 켜자마자 잔소리부터
    /// 하면 무엇 때문인지 알기 어렵다.
    mutating func due(now: Date) -> Bool {
        guard let last = lastAt else {
            lastAt = now
            return false
        }
        guard now.timeIntervalSince(last) >= interval else { return false }
        lastAt = now
        return true
    }

    /// 시계를 지금으로 다시 맞춘다. 조건이 사라져 한동안 쉬어야 할 때 쓴다.
    mutating func postpone(to now: Date) {
        lastAt = now
    }
}
