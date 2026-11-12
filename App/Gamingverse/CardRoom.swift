import RealityKit
import SwiftUI
import TabletopCore

/// Geometry of the immersive card room. The immersive space's origin is on the floor where you
/// are, facing -z, so the table sits just in front of you at real-world size.
enum CardRoomLayout {
    static let tableHeight: Float = 0.74
    static let tableCenter: SIMD3<Float> = [0, 0, -1.15]
    static let radiusX: Float = 1.1
    static let radiusZ: Float = 0.62
    /// Roughly where your head is when seated at the near edge of the table.
    static let humanHead: SIMD3<Float> = [0, 1.2, 0]
    static let roomSize: SIMD3<Float> = [9, 3.2, 9]

    /// A point on the table's edge, `inset` meters in from it (negative is outside the table).
    /// `angle` runs from 0 (your left) through π/2 (the far side) to π (your right).
    static func edgePoint(angle: Float, inset: Float = 0) -> SIMD3<Float> {
        let direction = SIMD3<Float>(-cos(angle), 0, -sin(angle))
        let edge = tableCenter + SIMD3(radiusX * direction.x, 0, radiusZ * direction.z)
        let normal = normalize(SIMD3(direction.x / radiusX, 0, direction.z / radiusZ))
        return edge - normal * inset
    }

    /// Bots sit around the far side of the table in dealing (clockwise) order, starting on your left.
    static func seatAngle(index: Int, of count: Int) -> Float {
        Float.pi * (Float(index) + 0.5) / Float(count)
    }

    /// Rotation about y that turns an entity's +z toward `target`.
    static func facing(from position: SIMD3<Float>, to target: SIMD3<Float>) -> simd_quatf {
        let direction = target - position
        return simd_quatf(angle: atan2(direction.x, direction.z), axis: [0, 1, 0])
    }

    /// Scales an attachment so it's `width` meters wide.
    static func fit(_ entity: Entity, width: Float) {
        let extents = entity.visualBounds(relativeTo: entity).extents
        guard extents.x > 0 else { return }
        entity.scale = .init(repeating: width / extents.x)
    }
}

// MARK: - Room

enum CardRoomBuilder {
    /// The spotlight over the table, which the director dims and tints for big moments.
    static let lampLightName = "lampLight"
    static let lampColor = UIColor(red: 1, green: 0.88, blue: 0.7, alpha: 1)
    static let lampIntensity: Float = 60000

    static func makeRoom() -> Entity {
        let room = Entity()
        let size = CardRoomLayout.roomSize
        let center = CardRoomLayout.tableCenter

        let floor = box([size.x, 0.02, size.z], color: UIColor(red: 0.22, green: 0.14, blue: 0.09, alpha: 1), roughness: 0.6)
        floor.position = [center.x, -0.01, center.z]
        room.addChild(floor)

        let ceiling = box([size.x, 0.02, size.z], color: UIColor(white: 0.08, alpha: 1))
        ceiling.position = [center.x, size.y, center.z]
        room.addChild(ceiling)

        let wallColor = UIColor(red: 0.42, green: 0.13, blue: 0.13, alpha: 1)
        let panelColor = UIColor(red: 0.17, green: 0.1, blue: 0.06, alpha: 1)
        for side in 0..<4 {
            let wall = Entity()
            let angle = Float(side) * .pi / 2
            wall.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
            wall.position = center + simd_quatf(angle: angle, axis: [0, 1, 0]).act([0, 0, -size.z / 2])

            let plaster = box([size.x, size.y, 0.05], color: wallColor, roughness: 0.9)
            plaster.position.y = size.y / 2
            wall.addChild(plaster)

            // Wood wainscoting along the bottom of the wall.
            let wainscot = box([size.x, 1.0, 0.04], color: panelColor, roughness: 0.5)
            wainscot.position = [0, 0.5, 0.04]
            wall.addChild(wainscot)

            for x: Float in [-2.2, 2.2] {
                wall.addChild(makeSconce(at: [x, 1.9, 0.06]))
            }
            room.addChild(wall)
        }

        let rug = ModelEntity(
            mesh: .generateCylinder(height: 0.01, radius: 1),
            materials: [SimpleMaterial(color: UIColor(red: 0.35, green: 0.08, blue: 0.1, alpha: 1), roughness: 1, isMetallic: false)]
        )
        rug.scale = [CardRoomLayout.radiusX + 1.4, 1, CardRoomLayout.radiusZ + 1.4]
        rug.position = [center.x, 0.005, center.z]
        room.addChild(rug)

        room.addChild(makeLamp())

        // Faint fill so the corners of the room aren't pitch black.
        let fill = Entity()
        var fillLight = PointLightComponent(color: UIColor(red: 1, green: 0.85, blue: 0.7, alpha: 1), intensity: 25000, attenuationRadius: 12)
        fillLight.attenuationFalloffExponent = 1
        fill.components.set(fillLight)
        fill.position = center + [0, 2.8, 0]
        room.addChild(fill)
        return room
    }

    static func makeTable() -> Entity {
        let table = Entity()
        let height = CardRoomLayout.tableHeight
        let rx = CardRoomLayout.radiusX
        let rz = CardRoomLayout.radiusZ
        table.position = CardRoomLayout.tableCenter

        let felt = ModelEntity(
            mesh: .generateCylinder(height: 0.03, radius: 1),
            materials: [SimpleMaterial(color: UIColor(red: 0.05, green: 0.36, blue: 0.2, alpha: 1), roughness: 0.95, isMetallic: false)]
        )
        felt.scale = [rx, 1, rz]
        felt.position.y = height - 0.015
        table.addChild(felt)

        let rail = ModelEntity(
            mesh: .generateCylinder(height: 0.06, radius: 1),
            materials: [SimpleMaterial(color: UIColor(red: 0.18, green: 0.09, blue: 0.05, alpha: 1), roughness: 0.35, isMetallic: false)]
        )
        rail.scale = [rx + 0.1, 1, rz + 0.1]
        rail.position.y = height - 0.035
        table.addChild(rail)

        let base = ModelEntity(
            mesh: .generateCylinder(height: height - 0.06, radius: 0.18),
            materials: [SimpleMaterial(color: UIColor(red: 0.12, green: 0.06, blue: 0.04, alpha: 1), roughness: 0.4, isMetallic: false)]
        )
        base.position.y = (height - 0.06) / 2
        table.addChild(base)
        table.components.set(GroundingShadowComponent(castsShadow: true))
        return table
    }

    /// A pendant lamp over the table: the main light in the room.
    private static func makeLamp() -> Entity {
        let lamp = Entity()
        let ceiling = CardRoomLayout.roomSize.y
        lamp.position = CardRoomLayout.tableCenter + [0, 1.75, 0]

        let cord = ModelEntity(mesh: .generateCylinder(height: ceiling - 1.75, radius: 0.006), materials: [SimpleMaterial(color: .black, isMetallic: false)])
        cord.position.y = (ceiling - 1.75) / 2 + 0.1
        lamp.addChild(cord)

        let shade = ModelEntity(
            mesh: .generateCone(height: 0.16, radius: 0.2),
            materials: [SimpleMaterial(color: UIColor(red: 0.75, green: 0.55, blue: 0.25, alpha: 1), roughness: 0.25, isMetallic: true)]
        )
        shade.position.y = 0.05
        lamp.addChild(shade)

        let bulb = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.9, blue: 0.7, alpha: 1))])
        bulb.position.y = -0.04
        lamp.addChild(bulb)

        let light = Entity()
        var spot = SpotLightComponent(color: lampColor, intensity: lampIntensity, innerAngleInDegrees: 50, outerAngleInDegrees: 85, attenuationRadius: 6)
        spot.attenuationFalloffExponent = 1.5
        light.components.set(spot)
        light.components.set(SpotLightComponent.Shadow())
        light.name = CardRoomBuilder.lampLightName
        light.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]) // point straight down
        light.position.y = -0.06
        lamp.addChild(light)
        return lamp
    }

    private static func makeSconce(at position: SIMD3<Float>) -> Entity {
        let sconce = Entity()
        sconce.position = position
        let plate = box([0.12, 0.2, 0.02], color: UIColor(red: 0.55, green: 0.42, blue: 0.2, alpha: 1), roughness: 0.3, metallic: true)
        sconce.addChild(plate)
        let glow = ModelEntity(mesh: .generateSphere(radius: 0.045), materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.75, blue: 0.45, alpha: 1))])
        glow.position = [0, 0.05, 0.05]
        sconce.addChild(glow)
        var light = PointLightComponent(color: UIColor(red: 1, green: 0.7, blue: 0.4, alpha: 1), intensity: 6000, attenuationRadius: 4)
        light.attenuationFalloffExponent = 2
        glow.components.set(light)
        return sconce
    }

    static func box(_ size: SIMD3<Float>, color: UIColor, roughness: Float = 0.8, metallic: Bool = false, cornerRadius: Float = 0) -> ModelEntity {
        ModelEntity(
            mesh: .generateBox(size: size, cornerRadius: cornerRadius),
            materials: [SimpleMaterial(color: color, roughness: .init(floatLiteral: roughness), isMetallic: metallic)]
        )
    }
}

// MARK: - Chips

/// A stack of poker chips whose height follows a chip count.
@MainActor
final class ChipStack {
    let entity = Entity()
    private let chipsPerDisc: Int
    private let maxDiscs: Int
    static let discHeight: Float = 0.0045
    static let colors: [UIColor] = [.systemRed, .systemBlue, .black, .systemGreen, .white]

    /// Where the next chip would sit, for chips flying onto or off the stack.
    var top: SIMD3<Float> { entity.position + [0, Float(entity.children.count) * Self.discHeight, 0] }

    init(chipsPerDisc: Int, maxDiscs: Int = 30) {
        self.chipsPerDisc = chipsPerDisc
        self.maxDiscs = maxDiscs
    }

    func update(chips: Int) {
        let discs = chips <= 0 ? 0 : min(maxDiscs, max(1, chips / chipsPerDisc))
        while entity.children.count > discs {
            entity.children[entity.children.count - 1].removeFromParent()
        }
        while entity.children.count < discs {
            let index = entity.children.count
            let disc = ModelEntity(
                mesh: .generateCylinder(height: Self.discHeight * 0.9, radius: 0.02),
                materials: [SimpleMaterial(color: Self.colors[(index / 5) % Self.colors.count], roughness: 0.5, isMetallic: false)]
            )
            disc.position.y = Self.discHeight * (Float(index) + 0.5)
            entity.addChild(disc)
        }
    }
}

// MARK: - Avatars

/// A seated, stylized opponent built from primitive shapes. Faces +z (toward the table) when unrotated.
@MainActor
final class AvatarRig {
    let root = Entity()
    /// Pivots at the hips so the upper body can lean back.
    private let body = Entity()
    private let torso: ModelEntity
    /// Pivots at the neck.
    private let head = Entity()
    private var eyes: [Entity] = []
    private let phase: Float
    private var nextBlink: Float
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var lean: Float = 0
    private var arms: [(shoulder: SIMD3<Float>, rest: SIMD3<Float>, hand: SIMD3<Float>, sleeve: ModelEntity, palm: ModelEntity)] = []
    private var tapStart: Float = -10
    private var bounce: Float = 0

    enum Pose {
        case rest
        /// Chin in the right hand while deciding.
        case thinking
        /// Both hands shoving chips toward the middle.
        case push
        /// Both arms in the air.
        case celebrate
    }

    var pose = Pose.rest

    static let seatHeight: Float = 0.47
    static let palette: [(shirt: UIColor, hair: UIColor, skin: UIColor)] = [
        (UIColor(red: 0.85, green: 0.55, blue: 0.15, alpha: 1), UIColor(red: 0.15, green: 0.1, blue: 0.08, alpha: 1), UIColor(red: 0.93, green: 0.78, blue: 0.65, alpha: 1)),
        (UIColor(red: 0.2, green: 0.4, blue: 0.75, alpha: 1), UIColor(red: 0.55, green: 0.35, blue: 0.2, alpha: 1), UIColor(red: 0.72, green: 0.53, blue: 0.4, alpha: 1)),
        (UIColor(red: 0.55, green: 0.25, blue: 0.6, alpha: 1), UIColor(red: 0.85, green: 0.7, blue: 0.4, alpha: 1), UIColor(red: 0.96, green: 0.84, blue: 0.74, alpha: 1)),
        (UIColor(red: 0.2, green: 0.55, blue: 0.45, alpha: 1), UIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1), UIColor(red: 0.45, green: 0.3, blue: 0.22, alpha: 1)),
        (UIColor(red: 0.75, green: 0.2, blue: 0.25, alpha: 1), UIColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1), UIColor(red: 0.85, green: 0.66, blue: 0.5, alpha: 1)),
    ]

    /// Position of the eyes in the room, for aiming other avatars' gazes.
    var headPosition: SIMD3<Float> { head.position(relativeTo: root.parent) + [0, 0.1, 0] }

    /// - Parameter reach: horizontal distance from the chair to where the hands rest on the table.
    init(styleIndex: Int, reach: Float) {
        let style = Self.palette[styleIndex % Self.palette.count]
        phase = Float(styleIndex) * 1.7
        nextBlink = Float.random(in: 1...4)
        let seat = Self.seatHeight

        // Chair
        let leather = UIColor(red: 0.12, green: 0.07, blue: 0.05, alpha: 1)
        let cushion = CardRoomBuilder.box([0.48, 0.07, 0.46], color: leather, roughness: 0.4, cornerRadius: 0.02)
        cushion.position.y = seat - 0.035
        root.addChild(cushion)
        let backrest = CardRoomBuilder.box([0.48, 0.55, 0.07], color: leather, roughness: 0.4, cornerRadius: 0.02)
        backrest.position = [0, seat + 0.3, -0.25]
        root.addChild(backrest)
        let post = ModelEntity(mesh: .generateCylinder(height: seat - 0.07, radius: 0.03), materials: [SimpleMaterial(color: .darkGray, isMetallic: true)])
        post.position.y = (seat - 0.07) / 2
        root.addChild(post)

        // Body
        body.position = [0, seat, -0.05]
        root.addChild(body)

        let shirt = SimpleMaterial(color: style.shirt, roughness: 0.8, isMetallic: false)
        torso = ModelEntity(mesh: .generateBox(size: [0.38, 0.52, 0.22], cornerRadius: 0.09), materials: [shirt])
        torso.position.y = 0.27
        body.addChild(torso)

        let skin = SimpleMaterial(color: style.skin, roughness: 0.7, isMetallic: false)
        let neck = ModelEntity(mesh: .generateCylinder(height: 0.08, radius: 0.045), materials: [skin])
        neck.position.y = 0.55
        body.addChild(neck)

        head.position.y = 0.58
        body.addChild(head)
        let skull = ModelEntity(mesh: .generateSphere(radius: 0.11), materials: [skin])
        skull.position.y = 0.1
        skull.scale = [0.92, 1.05, 1]
        head.addChild(skull)
        let hair = ModelEntity(mesh: .generateSphere(radius: 0.115), materials: [SimpleMaterial(color: style.hair, roughness: 0.9, isMetallic: false)])
        hair.position = [0, 0.15, -0.02]
        hair.scale = [0.95, 0.65, 1]
        head.addChild(hair)
        for x: Float in [-0.038, 0.038] {
            let eye = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [SimpleMaterial(color: UIColor(white: 0.05, alpha: 1), roughness: 0.2, isMetallic: false)])
            eye.position = [x, 0.11, 0.098]
            head.addChild(eye)
            eyes.append(eye)
        }

        // Arms run from the shoulders to the hands, which rest on the table unless posing.
        let handY = CardRoomLayout.tableHeight + 0.03 - seat
        for side: Float in [-1, 1] {
            let shoulder = SIMD3<Float>(side * 0.2, 0.46, 0)
            let rest = SIMD3<Float>(side * 0.16, handY, reach)
            let sleeve = ModelEntity(mesh: .generateCylinder(height: 1, radius: 0.04), materials: [shirt])
            let palm = ModelEntity(mesh: .generateSphere(radius: 0.045), materials: [skin])
            palm.scale = [0.8, 0.5, 1]
            body.addChild(sleeve)
            body.addChild(palm)
            arms.append((shoulder, rest, rest, sleeve, palm))
        }
        placeArms()

        root.components.set(GroundingShadowComponent(castsShadow: true))
    }

    /// Per-frame idle animation: breathing, blinking, turning the head toward `lookTarget` (room space)
    /// and leaning back after folding.
    func animate(time: Float, deltaTime: Float, lookTarget: SIMD3<Float>, isFolded: Bool) {
        torso.scale.y = 1 + 0.015 * sin(time * 1.6 + phase)

        let blinking = time >= nextBlink
        for eye in eyes { eye.scale.y = blinking ? 0.1 : 1 }
        if time >= nextBlink + 0.12 {
            nextBlink = time + Float.random(in: 2...6)
        }

        let local = root.orientation.inverse.act(lookTarget - headPosition)
        let targetYaw = min(max(atan2(local.x, local.z), -1.2), 1.2)
        let targetPitch = atan2(local.y, length(SIMD2(local.x, local.z)))
        let blend = min(1, deltaTime * 3)
        yaw += (targetYaw - yaw) * blend
        pitch += (targetPitch - pitch) * blend
        lean += ((isFolded ? 0.14 : 0) - lean) * min(1, deltaTime * 2)

        head.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0])
        body.orientation = simd_quatf(angle: -lean, axis: [1, 0, 0])

        // Hands ease toward the pose; a tap lifts the right hand and brings it down on the felt.
        let tap = 0.07 * sin(.pi * min(max((time - tapStart) / 0.35, 0), 1))
        for index in arms.indices {
            let side: Float = index == 0 ? -1 : 1
            var target = arms[index].rest
            switch pose {
            case .rest:
                break
            case .thinking where side > 0:
                target = [0.03, 0.6, 0.14]
            case .thinking:
                break
            case .push:
                target = arms[index].rest + [0, 0.03, 0.2]
            case .celebrate:
                target = [side * 0.3, 1.0 + 0.04 * sin(time * 9 + side), 0.05]
            }
            if side > 0 { target.y += tap }
            arms[index].hand += (target - arms[index].hand) * min(1, deltaTime * 7)
        }
        placeArms()

        bounce += ((pose == .celebrate ? 1 : 0) - bounce) * min(1, deltaTime * 5)
        body.position.y = Self.seatHeight + bounce * 0.03 * abs(sin(time * 9))
    }

    /// Raps the table, e.g. to check.
    func tap(at time: Float) {
        tapStart = time
    }

    private func placeArms() {
        for arm in arms {
            let span = arm.hand - arm.shoulder
            arm.sleeve.position = (arm.shoulder + arm.hand) / 2
            arm.sleeve.orientation = simd_quatf(from: [0, 1, 0], to: normalize(span))
            arm.sleeve.scale = [1, length(span), 1]
            arm.palm.position = arm.hand
        }
    }
}
