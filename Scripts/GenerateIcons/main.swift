#!/usr/bin/env swift
//
// 生成占位图标素材：AppIcon 全尺寸 + 菜单栏 Template 图标。
// 没有美术素材时用它产出可交付的完整尺寸集，后续替换 PNG 即可。
//
// 用法：swift Scripts/GenerateIcons/main.swift <Assets.xcassets 路径>
//

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets: URL
if CommandLine.arguments.count > 1 {
    assets = URL(fileURLWithPath: CommandLine.arguments[1])
} else {
    assets = root.appendingPathComponent("HostApp/Resources/Assets.xcassets")
}

let appIconSet = assets.appendingPathComponent("AppIcon.appiconset")
let menuBarSet = assets.appendingPathComponent("MenuBarIcon.imageset")
try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: menuBarSet, withIntermediateDirectories: true)

func makeContext(size: Int) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("无法创建绘图上下文")
    }
    return context
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG 编码失败：\(url.lastPathComponent)")
    }
    try data.write(to: url)
}

/// 应用图标：圆角矩形渐变底 + 极简「机箱前面板」几何标记。
func drawAppIcon(size: Int, to url: URL) throws {
    let context = makeContext(size: size)
    let s = CGFloat(size)

    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(path)
    context.clip()

    let colors = [
        CGColor(red: 0.16, green: 0.52, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.05, green: 0.28, blue: 0.72, alpha: 1.0),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // 高光
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    context.fillEllipse(in: CGRect(x: -s * 0.25, y: s * 0.45, width: s * 0.9, height: s * 0.9))

    // 前面板外框
    let panel = rect.insetBy(dx: s * 0.24, dy: s * 0.20)
    let panelPath = CGPath(
        roundedRect: panel,
        cornerWidth: panel.width * 0.16,
        cornerHeight: panel.width * 0.16,
        transform: nil
    )
    context.addPath(panelPath)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    context.setLineWidth(s * 0.032)
    context.strokePath()

    // 两条插槽
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    let slotWidth = panel.width * 0.52
    let slotHeight = panel.height * 0.10
    let slotX = panel.midX - slotWidth / 2
    for ratio in [0.28, 0.52] {
        let slotY = panel.minY + panel.height * CGFloat(ratio)
        let slot = CGRect(x: slotX, y: slotY, width: slotWidth, height: slotHeight)
        context.addPath(CGPath(roundedRect: slot, cornerWidth: slotHeight / 2, cornerHeight: slotHeight / 2, transform: nil))
        context.fillPath()
    }

    // 指示灯
    let light = CGRect(x: panel.midX - panel.width * 0.05, y: panel.minY + panel.height * 0.76, width: panel.width * 0.10, height: panel.width * 0.10)
    context.fillEllipse(in: light)

    context.restoreGState()

    guard let image = context.makeImage() else { fatalError("图标渲染失败") }
    try writePNG(image, to: url)
}

/// 菜单栏图标：纯黑 Template，系统按菜单栏明暗自动着色。
func drawMenuBarIcon(size: Int, to url: URL) throws {
    let context = makeContext(size: size)
    let s = CGFloat(size)
    let stroke = max(1, s * 0.09)

    let rect = CGRect(x: s * 0.14, y: s * 0.18, width: s * 0.72, height: s * 0.64)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
    context.addPath(path)
    context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.setLineWidth(stroke)
    context.strokePath()

    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    let slotWidth = rect.width * 0.5
    let slotHeight = max(1, s * 0.10)
    for ratio in [0.30, 0.56] {
        let slot = CGRect(
            x: rect.midX - slotWidth / 2,
            y: rect.minY + rect.height * CGFloat(ratio),
            width: slotWidth,
            height: slotHeight
        )
        context.addPath(CGPath(roundedRect: slot, cornerWidth: slotHeight / 2, cornerHeight: slotHeight / 2, transform: nil))
        context.fillPath()
    }

    guard let image = context.makeImage() else { fatalError("菜单栏图标渲染失败") }
    try writePNG(image, to: url)
}

// AppIcon：macOS 完整尺寸集
let appIconEntries: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for entry in appIconEntries {
    try drawAppIcon(size: entry.size, to: appIconSet.appendingPathComponent(entry.name))
}

// 菜单栏 Template 图标
try drawMenuBarIcon(size: 18, to: menuBarSet.appendingPathComponent("MenuBarIcon.png"))
try drawMenuBarIcon(size: 36, to: menuBarSet.appendingPathComponent("MenuBarIcon@2x.png"))
try drawMenuBarIcon(size: 54, to: menuBarSet.appendingPathComponent("MenuBarIcon@3x.png"))

print("图标已生成：\(assets.path)")
