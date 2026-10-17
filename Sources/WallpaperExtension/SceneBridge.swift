import CoreGraphics
import Foundation

@objc(FSSceneFrame)
final class FSSceneFrame: NSObject {
    @objc(drawScene:time:dimming:context:width:height:)
    static func drawScene(_ scene: String, time: Double, dimming: Double, context: CGContext, width: Int, height: Int) {
        SceneDrawing.render(scene: scene, time: time, dimming: dimming, in: context,
                            bounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    }
}
