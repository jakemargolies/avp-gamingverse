// Draws the app icon's three layers into the asset catalog.
// Usage, from the repo root: swift Tools/MakeAppIcon.swift
//
// visionOS icons are a stack of 1024×1024 layers that separate in depth when you look at them:
// an opaque back (felt), a middle (a pair of cards) and a front (a chip). The system crops to a circle.

import AppKit
import SwiftUI

let size: CGFloat = 1024
let stack = "App/Gamingverse/Assets.xcassets/AppIcon.solidimagestack"

struct Back: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(red: 0.12, green: 0.55, blue: 0.3), Color(red: 0.02, green: 0.22, blue: 0.12)],
                center: .center, startRadius: 40, endRadius: 560
            )
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.45), Color(red: 0.6, green: 0.42, blue: 0.15)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 22
                )
                .padding(70)
                .opacity(0.8)
        }
        .frame(width: size, height: size)
    }
}

struct PlayingCard: View {
    let rank: String
    let suit: String
    let color: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        ZStack {
            shape.fill(.white)
            VStack(spacing: -30) {
                Text(rank).font(.system(size: 170, weight: .heavy, design: .rounded))
                Text(suit).font(.system(size: 170))
            }
            .foregroundStyle(color)
        }
        .frame(width: 300, height: 420)
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }
}

struct Middle: View {
    var body: some View {
        ZStack {
            PlayingCard(rank: "K", suit: "♥", color: Color(red: 0.85, green: 0.1, blue: 0.15))
                .rotationEffect(.degrees(14))
                .offset(x: 80, y: -10)
            PlayingCard(rank: "A", suit: "♠", color: .black)
                .rotationEffect(.degrees(-12))
                .offset(x: -80, y: 0)
        }
        .offset(y: -30)
        .frame(width: size, height: size)
    }
}

struct Front: View {
    var body: some View {
        let red = Color(red: 0.82, green: 0.1, blue: 0.12)
        ZStack {
            Circle().fill(red)
            // Edge stripes, as on a casino chip.
            ForEach(0..<8) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 34, height: 62)
                    .offset(y: -128)
                    .rotationEffect(.degrees(Double(index) * 45))
            }
            Circle().fill(red).padding(52)
            Circle().strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 8, dash: [18, 12])).padding(64)
            Text("$")
                .font(.system(size: 120, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 320, height: 320)
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .offset(x: 145, y: 185)
        .frame(width: size, height: size)
    }
}

@MainActor
func write(_ view: some View, layer: String, opaque: Bool) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    renderer.isOpaque = opaque
    guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    let folder = URL(fileURLWithPath: "\(stack)/\(layer).solidimagestacklayer/Content.imageset")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try png.write(to: folder.appendingPathComponent("\(layer.lowercased()).png"))

    let imageSet = """
    {
      "images" : [ { "filename" : "\(layer.lowercased()).png", "idiom" : "vision", "scale" : "2x" } ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
    try imageSet.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(
        to: folder.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

try MainActor.assumeIsolated {
    try write(Back(), layer: "Back", opaque: true)
    try write(Middle(), layer: "Middle", opaque: false)
    try write(Front(), layer: "Front", opaque: false)
}

let stackContents = """
{
  "info" : { "author" : "xcode", "version" : 1 },
  "layers" : [
    { "filename" : "Front.solidimagestacklayer" },
    { "filename" : "Middle.solidimagestacklayer" },
    { "filename" : "Back.solidimagestacklayer" }
  ]
}
"""
try stackContents.write(toFile: "\(stack)/Contents.json", atomically: true, encoding: .utf8)
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(
    toFile: "App/Gamingverse/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
print("Wrote \(stack)")
