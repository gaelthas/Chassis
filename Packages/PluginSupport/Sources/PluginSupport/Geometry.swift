import AppKit
import CoreGraphics

/// 坐标换算纯函数：AppKit 用左下原点，CGEvent / AX 用左上原点，多屏时两者都要按屏幕高度翻转。
public enum Geometry {
    /// 主轴（主屏）高度，用于一次翻转。
    public static func primaryHeight() -> CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    public static func topLeftPoint(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func appKitPoint(fromTopLeft point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func topLeftRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// 点是否落在某个屏幕矩形内（左上坐标系）。
    public static func contains(_ point: CGPoint, in rects: [CGRect]) -> Bool {
        rects.contains { $0.contains(point) }
    }
}
