import Metal
import RealityKit
import SwiftUI
import TabletopCore

/// Drives time-based animations from RealityKit's per-frame update. Each animation calls its
/// `update` closure with progress from 0 to 1; `animate` can be awaited until it finishes, so
/// sequences read top to bottom.
@MainActor
final class Animator {
    private struct Tween {
        let start: Float
        let duration: Float
        let update: (Float) -> Void
        var completion: CheckedContinuation<Void, Never>?
    }

    private(set) var time: Float = 0
    private var tweens: [Int: Tween] = [:]
    private var nextID = 0
    private var isStopped = false

    func step(_ deltaTime: Float) {
        time += deltaTime
        for (id, tween) in tweens where time >= tween.start {
            let progress = tween.duration > 0 ? min(1, (time - tween.start) / tween.duration) : 1
            tween.update(progress)
            if progress >= 1 {
                tweens[id] = nil
                tween.completion?.resume()
            }
        }
    }

    /// Runs an animation and waits for it to finish.
    func animate(duration: Float, delay: Float = 0, _ update: @escaping (Float) -> Void) async {
        await withCheckedContinuation { continuation in
            add(Tween(start: time + delay, duration: duration, update: update, completion: continuation))
        }
    }

    /// Starts an animation without waiting for it.
    func run(duration: Float, delay: Float = 0, _ update: @escaping (Float) -> Void) {
        add(Tween(start: time + delay, duration: duration, update: update))
    }

    func wait(_ seconds: Float) async {
        await animate(duration: seconds) { _ in }
    }

    /// Jumps every animation to its end and finishes any started later immediately. For when the
    /// scene goes away and frames stop arriving, so nothing waits forever.
    func stop() {
        isStopped = true
        let pending = tweens.values
        tweens = [:]
        for tween in pending {
            tween.update(1)
            tween.completion?.resume()
        }
    }

    private func add(_ tween: Tween) {
        if isStopped {
            tween.update(1)
            tween.completion?.resume()
            return
        }
        tweens[nextID] = tween
        nextID += 1
    }

    // MARK: - Common moves

    /// Flies `entity` to `position` along an arc, optionally turning to `orientation` and spinning
    /// about y on the way. The start is read when the flight begins, so flights can be queued.
    func fly(_ entity: Entity, to position: SIMD3<Float>, orientation: simd_quatf? = nil, arc: Float = 0.1,
             spins: Float = 0, duration: Float, delay: Float = 0) async {
        await animate(duration: duration, delay: delay, flight(entity, position, orientation, arc, spins))
    }

    func launch(_ entity: Entity, to position: SIMD3<Float>, orientation: simd_quatf? = nil, arc: Float = 0.1,
                spins: Float = 0, duration: Float, delay: Float = 0) {
        run(duration: duration, delay: delay, flight(entity, position, orientation, arc, spins))
    }

    private func flight(_ entity: Entity, _ end: SIMD3<Float>, _ endOrientation: simd_quatf?, _ arc: Float, _ spins: Float) -> (Float) -> Void {
        var start: (position: SIMD3<Float>, orientation: simd_quatf)?
        return { progress in
            if start == nil { start = (entity.position, entity.orientation) }
            let t = Ease.inOutCubic(progress)
            var position = mix(start!.position, end, t: t)
            position.y += arc * 4 * progress * (1 - progress)
            entity.position = position
            let target = endOrientation ?? start!.orientation
            let spin = simd_quatf(angle: spins * 2 * .pi * (1 - t), axis: [0, 1, 0])
            entity.orientation = spin * simd_slerp(start!.orientation, target, t)
        }
    }

    func fade(_ entity: Entity, to opacity: Float, duration: Float, delay: Float = 0) {
        var start: Float?
        run(duration: duration, delay: delay) { progress in
            if start == nil { start = entity.components[OpacityComponent.self]?.opacity ?? 1 }
            entity.components.set(OpacityComponent(opacity: start! + (opacity - start!) * progress))
        }
    }

    /// Scales in from nothing with a slight overshoot.
    func pop(_ entity: Entity, to scale: Float = 1, duration: Float = 0.45, delay: Float = 0) {
        entity.scale = .zero
        run(duration: duration, delay: delay) { progress in
            entity.scale = .init(repeating: scale * Ease.outBack(progress))
        }
    }
}

enum Ease {
    static func inOutCubic(_ t: Float) -> Float {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    static func outCubic(_ t: Float) -> Float { 1 - pow(1 - t, 3) }

    static func outBack(_ t: Float) -> Float {
        let c1: Float = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}

// MARK: - Labels

enum Label3D {
    /// Extruded text centered on its entity's origin, facing +z.
    static func make(_ text: String, height: Float, color: UIColor, weight: UIFont.Weight = .heavy) -> Entity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: height * 0.12,
            font: .systemFont(ofSize: CGFloat(height), weight: weight),
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        let glyphs = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        glyphs.position = -mesh.bounds.center
        let label = Entity()
        label.addChild(glyphs)
        return label
    }
}

// MARK: - Cards

/// Card faces rendered once from `CardView` and reused as textures for 3D cards.
@MainActor
final class CardTextures {
    private static var cached: CardTextures?

    private var faces: [Card: PhysicallyBasedMaterial] = [:]
    private(set) var back = PhysicallyBasedMaterial()
    private(set) var turnRing = UnlitMaterial()

    static func load() async -> CardTextures {
        if let cached { return cached }
        let textures = CardTextures()
        for card in Card.fullDeck {
            textures.faces[card] = await material(for: CardView(card: card, width: 240))
        }
        textures.back = await material(for: CardView(card: nil, width: 240))
        if let ring = await texture(for: TurnRingImage()) {
            var material = UnlitMaterial()
            material.color = .init(texture: .init(ring))
            material.blending = .transparent(opacity: .init(scale: 1, texture: alphaOf(ring)))
            textures.turnRing = material
        }
        cached = textures
        return textures
    }

    func face(_ card: Card) -> PhysicallyBasedMaterial { faces[card] ?? back }

    /// Opacity textures read the red channel by default, which would cut out dark ink and blue backs.
    private static func alphaOf(_ resource: TextureResource) -> MaterialParameters.Texture {
        var texture = MaterialParameters.Texture(resource)
        texture.swizzle = MTLTextureSwizzleChannels(red: .alpha, green: .alpha, blue: .alpha, alpha: .alpha)
        return texture
    }

    private static func material(for view: some View) async -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.roughness = 0.6
        if let texture = await texture(for: view) {
            material.baseColor = .init(texture: .init(texture))
            // Cut out the rounded corners using the image's alpha.
            material.blending = .transparent(opacity: .init(scale: 1, texture: alphaOf(texture)))
            material.opacityThreshold = 0.5
        }
        return material
    }

    private static func texture(for view: some View) async -> TextureResource? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return try? await TextureResource(image: image, options: .init(semantic: .color))
    }
}

/// The glowing ring drawn on the felt in front of whoever's turn it is.
private struct TurnRingImage: View {
    var body: some View {
        Circle()
            .stroke(Color(red: 1, green: 0.85, blue: 0.4), lineWidth: 14)
            .shadow(color: .yellow, radius: 18)
            .padding(40)
            .frame(width: 512, height: 512)
    }
}

/// A 3D playing card: two back-to-back planes lying flat, face up along +y when unflipped.
@MainActor
final class CardEntity {
    let card: Card
    /// Position and heading of the card.
    let entity = Entity()
    /// Flips and lifts within `entity`.
    let body = Entity()
    private let glow: ModelEntity

    static let aspect: Float = 1.4

    init(_ card: Card, textures: CardTextures, width: Float, faceUp: Bool = false) {
        self.card = card
        let size = SIMD2(width, width * Self.aspect)
        let face = ModelEntity(mesh: .generatePlane(width: size.x, depth: size.y), materials: [textures.face(card)])
        face.position.y = 0.0004
        let back = ModelEntity(mesh: .generatePlane(width: size.x, depth: size.y), materials: [textures.back])
        back.orientation = simd_quatf(angle: .pi, axis: [0, 0, 1])
        back.position.y = -0.0004
        glow = ModelEntity(
            mesh: .generatePlane(width: size.x * 1.18, depth: size.y * 1.13, cornerRadius: width * 0.12),
            materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.8, blue: 0.25, alpha: 1))]
        )
        glow.position.y = -0.0012
        glow.isEnabled = false
        body.addChild(face)
        body.addChild(back)
        body.addChild(glow)
        entity.addChild(body)
        body.orientation = faceUp ? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) : Self.faceDown
        entity.components.set(GroundingShadowComponent(castsShadow: true))
    }

    static let faceDown = simd_quatf(angle: .pi, axis: [0, 0, 1])
    var isFaceUp: Bool { abs(body.orientation.angle) < 0.1 }

    /// Lifts the card, turns it over and sets it back down.
    func flip(using animator: Animator, faceUp: Bool = true, lift: Float = 0.05, duration: Float = 0.4, delay: Float = 0) async {
        let start = body.orientation
        let end = faceUp ? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) : Self.faceDown
        await animator.animate(duration: duration, delay: delay) { [body] progress in
            let t = Ease.inOutCubic(progress)
            body.orientation = simd_slerp(start, end, t)
            body.position.y = lift * sin(.pi * progress)
        }
    }

    /// Raises the card with a gold outline, for the cards that make the winning hand.
    func highlight(using animator: Animator) {
        glow.isEnabled = true
        animator.pop(glow, duration: 0.5)
        animator.run(duration: 0.4) { [body] progress in
            body.position.y = 0.02 * Ease.outCubic(progress)
        }
    }
}
