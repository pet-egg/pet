import Foundation

/// The two fixed roles in a battle. Roles are stable across both peers (they're
/// decided by who initiated the challenge), so a battle simulated from the same
/// seed produces an identical script and winner on *both* machines — nobody has
/// to trust the other side's rendering. Each app maps "am I the challenger or
/// the accepter?" onto its own side of the screen at render time.
enum BattleRole: String, Codable {
    case challenger
    case accepter

    var opponent: BattleRole { self == .challenger ? .accepter : .challenger }
}

/// One exchange in the scripted battle: `attacker` fires. If `dodged`, the
/// defender turned away and hopped back — the projectile misses and `damage` is
/// 0; otherwise it connects for `damage`. Both peers compute the same dodges
/// from the shared seed, so the miss animation lines up on both screens.
struct BattleRound: Equatable {
    let attacker: BattleRole
    let damage: Int
    let dodged: Bool
    /// 반격 — 회피처럼 피해가 0 이지만, 막아 낸 쪽이 **다음 자기 차례에 두 발**을 쏜다.
    var countered: Bool = false

    /// 맞지 않은 공격. 회피든 반격이든 화면에서는 똑같이 빗나가게 그린다.
    var missed: Bool { dodged || countered }
}

/// The full deterministic result of one battle. `rounds` is the blow-by-blow
/// used to drive the on-screen projectile animation; `winner` is who's left
/// standing. Both peers compute this identically from the shared seed.
struct BattleOutcome: Equatable {
    let rounds: [BattleRound]
    let winner: BattleRole
    let startHP: Int
}

/// Tiny seeded PRNG (xorshift64*), used instead of `UInt64.random` so both
/// peers get the *same* sequence from the same seed. `Int.random`/`Math.random`
/// would diverge between machines — the whole point is a shared, reproducible
/// battle script from a single number sent over the wire.
struct DeterministicRNG {
    private var state: UInt64

    init(seed: UInt64) {
        // xorshift64* dies on a zero state — nudge it to a fixed nonzero constant.
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }

    /// Uniform-ish int in `range` (small ranges, modulo bias is negligible here).
    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}

/// 펫의 성장 상태를 0...1 하나로 압축한 "파워".
///
/// 1.0 은 **최종 진화 + 경험치 만렙**이고, 그 상태면 파워 0 인 상대를 한 방에 눕힌다
/// (아래 damage 식에서 보너스가 startHP-1 이 되어 기본 굴림 1~2 를 더하면 HP 를 넘는다).
/// 진화 단계는 곱연산으로 얹는다 — 1단계 +15%, 2단계 +30%.
func battlePower(tokens: Double, stage: Int) -> Double {
    let xp = min(1, max(0, tokens / XPModel.maxTokens))
    let stageMultiplier: Double = [1.0, 1.15, 1.30][min(max(stage, 0), 2)]
    // 최대치(경험치 만렙 × 2단계)가 정확히 1.0 이 되도록 나눠 준다.
    return min(1, xp * stageMultiplier / 1.30)
}

/// 회피 확률(%). 이 구간에 들어오면 피해 0.
private let dodgePercent = 10
/// 반격 확률(%). 회피 구간 **바로 다음** 구간이라 둘은 겹치지 않는다.
private let counterPercent = 5

/// Simulate a full battle from `seed`. 기본은 한 대씩 주고받는 교대 공격이다.
///
/// 한 발마다 `dodgePercent`% 로 회피(피해 0), 그 다음 `counterPercent`% 로 반격이
/// 난다. 반격은 피해를 막을 뿐 아니라 **막아 낸 쪽이 다음 자기 차례에 두 발**을 쏜다.
/// 맞으면 기본 1~2 에 공격자의 파워 보너스가 더해진다.
///
/// 회피도 반격도 전투를 끝내지 않으므로 마지막 라운드는 항상 적중이다.
/// Deterministic: same seed + same powers in → same `BattleOutcome` out, on any machine.
func simulateBattle(seed: UInt64,
                    powers: [BattleRole: Double] = [.challenger: 0, .accepter: 0],
                    startHP: Int = 5) -> BattleOutcome {
    var rng = DeterministicRNG(seed: seed)
    var hp: [BattleRole: Int] = [.challenger: startHP, .accepter: startHP]
    var rounds: [BattleRound] = []
    /// 반격에 성공해서 다음 차례에 두 발을 쏠 권리를 가진 쪽.
    var doubleShot: [BattleRole: Bool] = [.challenger: false, .accepter: false]

    // Coin-flip who strikes first, then strictly alternate.
    var attacker: BattleRole = rng.int(in: 0...1) == 0 ? .challenger : .accepter

    // The `< 200` guard is a pure safety net against a logic bug looping forever;
    // with a few HP a real battle resolves in a handful of rounds.
    while hp[.challenger]! > 0 && hp[.accepter]! > 0 && rounds.count < 200 {
        let target = attacker.opponent
        let shots = doubleShot[attacker]! ? 2 : 1
        doubleShot[attacker] = false

        for _ in 0..<shots {
            guard hp[target]! > 0 else { break }
            // 한 번의 굴림으로 회피/반격/적중을 가른다 — 두 번 굴리면 같은 시드에서도
            // 소비하는 난수 개수가 달라져 재현이 깨진다.
            let roll = rng.int(in: 0...99)
            let dodged = roll < dodgePercent
            let countered = !dodged && roll < dodgePercent + counterPercent

            var damage = 0
            if !dodged && !countered {
                // 기존 산정식(1~2)은 그대로 두고 성장 보너스를 더한다. 파워 1.0 이면
                // 보너스가 startHP-1 이라 어떤 굴림이든 한 방에 끝난다.
                let bonus = Int((Double(startHP - 1) * (powers[attacker] ?? 0)).rounded())
                damage = rng.int(in: 1...2) + bonus
                hp[target]! -= damage
            }
            if countered { doubleShot[target] = true }
            rounds.append(BattleRound(attacker: attacker, damage: damage,
                                      dodged: dodged, countered: countered))
        }
        attacker = target
    }

    // Winner is simply whoever still has HP left (exactly one side can hit 0,
    // since only the defender takes damage each round).
    let winner: BattleRole = hp[.challenger]! <= 0 ? .accepter : .challenger
    return BattleOutcome(rounds: rounds, winner: winner, startHP: startHP)
}
