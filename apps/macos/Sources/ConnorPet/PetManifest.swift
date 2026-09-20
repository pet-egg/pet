import Foundation

/// Mirrors Orca's `pet.json` manifest shape (`pet-bundle-manifest-schema.ts`).
struct PetManifest: Codable {
    struct Frame: Codable {
        let width: Int
        let height: Int
    }
    struct Animation: Codable {
        let row: Int
        let frames: Int
        let frameDurationsMs: [Double]?
    }

    let id: String?
    let displayName: String?
    let description: String?
    let spritesheetPath: String?
    let frame: Frame
    let fps: Double
    let defaultAnimation: String?
    let animations: [String: Animation]

    /// 속성기(불뿜기·물뿜기…) 연출용 부가 정보. 이펙트는 스프라이트시트가 아니라
    /// 별도 창에 그려지므로(FlameWindow), 어떤 행이 속성기인지, 어떤 이펙트 그림을
    /// 쓰는지, 프레임마다 입이 어디이고 이펙트가 얼마나 커졌는지를 앱이 알아야 한다.
    /// 속성기가 없는 펫에는 아예 없는 필드다.
    struct Skill: Codable {
        struct MouthFrame: Codable {
            let x: Double
            let y: Double
            let grow: Double
        }
        /// animations 의 어느 행이 속성기인가 (예: "fire-breath", "water-gun")
        let row: String
        /// Resources/effects/ 안의 이펙트 그림 파일명
        let effect: String
        let mouthByFrame: [MouthFrame]
    }
    let skill: Skill?

    static func load(from url: URL) throws -> PetManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PetManifest.self, from: data)
    }
}
