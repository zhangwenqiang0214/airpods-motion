import SwiftUI
import SceneKit

// MARK: - 3D 头部模型

final class HeadScene {
    let scene = SCNScene()
    let head  = SCNNode()

    // 颅骨半轴
    private let RX = 0.88, RY = 1.00, RZ = 0.92

    private let skin   = NSColor(calibratedRed: 0.95, green: 0.81, blue: 0.70, alpha: 1)
    private let shade  = NSColor(calibratedRed: 0.84, green: 0.68, blue: 0.57, alpha: 1)
    private let socket = NSColor(calibratedRed: 0.70, green: 0.53, blue: 0.45, alpha: 1)
    private let hairC  = NSColor(calibratedRed: 0.14, green: 0.12, blue: 0.12, alpha: 1)
    private let lipC   = NSColor(calibratedRed: 0.74, green: 0.34, blue: 0.32, alpha: 1)

    private var sp = 0.0, sy = 0.0, sr = 0.0

    init() { build() }

    /// 颅骨表面定位:az=方位角(0=正前,正值朝屏幕右),el=仰角,out=沿法线外移
    private func onSkull(_ az: Double, _ el: Double, out: Double = 0.0) -> SCNVector3 {
        let a = az * .pi / 180, e = el * .pi / 180
        let dx = cos(e) * sin(a), dy = sin(e), dz = cos(e) * cos(a)
        return SCNVector3((RX + out) * dx, (RY + out) * dy, (RZ + out) * dz)
    }

    /// 一律 lambert:零高光,五官靠明度差读出来
    private func mk(_ g: SCNGeometry, _ c: NSColor, _ pos: SCNVector3,
                    scale: SCNVector3 = SCNVector3(1, 1, 1),
                    euler: SCNVector3 = SCNVector3(0, 0, 0),
                    glossy: Bool = false) -> SCNNode {
        let m = SCNMaterial()
        if glossy {
            m.lightingModel = .blinn
            m.specular.contents = NSColor(white: 0.5, alpha: 1)
            m.shininess = 0.3
        } else {
            m.lightingModel = .lambert
            m.specular.contents = NSColor.black
        }
        m.diffuse.contents = c
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.position = pos; n.scale = scale; n.eulerAngles = euler
        return n
    }

    private func sph(_ r: CGFloat) -> SCNSphere {
        let s = SCNSphere(radius: r); s.segmentCount = 72; return s
    }

    private func build() {
        // ---- 颅骨:唯一的头部主体,不再叠任何"脸盘" ----
        head.addChildNode(mk(sph(1.0), skin, SCNVector3(0, 0, 0),
                             scale: SCNVector3(RX, RY, RZ)))
        // 下巴:向前下方收一点
        head.addChildNode(mk(sph(0.26), skin, onSkull(0, -56, out: -0.14),
                             scale: SCNVector3(1.2, 0.9, 1.0)))

        // ---- 头发:比颅骨略大并后移,只盖住顶+后,前脸露出 ----
        head.addChildNode(mk(sph(1.0), hairC, SCNVector3(0, 0.11, -0.135),
                             scale: SCNVector3(RX + 0.07, RY + 0.07, RZ + 0.07)))

        // ---- 眼 ----
        for az in [-23.0, 23.0] {
            // 眼窝(暗,给五官打底)
            head.addChildNode(mk(sph(0.155), socket, onSkull(az, 3, out: 0.005),
                                 scale: SCNVector3(1.35, 0.88, 0.40)))
            // 眼白
            head.addChildNode(mk(sph(0.105), NSColor(white: 0.97, alpha: 1),
                                 onSkull(az, 3, out: 0.04),
                                 scale: SCNVector3(1.25, 0.8, 0.3)))
            // 瞳孔
            head.addChildNode(mk(sph(0.055), hairC, onSkull(az, 3, out: 0.065),
                                 scale: SCNVector3(1, 1, 0.3)))
        }
        // 眉毛
        for (az, tilt) in [(-23.0, -0.14), (23.0, 0.14)] {
            head.addChildNode(mk(SCNBox(width: 0.36, height: 0.085, length: 0.12, chamferRadius: 0.04),
                                 hairC, onSkull(az, 16, out: 0.05),
                                 euler: SCNVector3(0, 0, tilt)))
        }

        // ---- 鼻 ----
        head.addChildNode(mk(SCNBox(width: 0.13, height: 0.30, length: 0.16, chamferRadius: 0.06),
                             skin, onSkull(0, -3, out: 0.03)))
        head.addChildNode(mk(sph(0.115), skin, onSkull(0, -13, out: 0.07),
                             scale: SCNVector3(1.2, 0.85, 0.9)))
        for az in [-4.5, 4.5] {
            head.addChildNode(mk(sph(0.042), socket, onSkull(az, -17, out: 0.085),
                                 scale: SCNVector3(1, 0.7, 0.6)))
        }

        // ---- 嘴 ----
        head.addChildNode(mk(SCNBox(width: 0.42, height: 0.10, length: 0.14, chamferRadius: 0.05),
                             lipC, onSkull(0, -32, out: 0.015)))

        // ---- 耳 ----
        for az in [-90.0, 90.0] {
            head.addChildNode(mk(sph(0.27), shade, onSkull(az, -2, out: -0.01),
                                 scale: SCNVector3(0.30, 1.12, 0.85)))
        }
        // 右耳白色 AirPod:左右镜像的判据
        head.addChildNode(mk(SCNCapsule(capRadius: 0.058, height: 0.28),
                             NSColor(white: 0.98, alpha: 1),
                             onSkull(93, -13, out: 0.0),
                             euler: SCNVector3(0, 0, 0.2), glossy: true))

        scene.rootNode.addChildNode(head)

        // ---- 静止参照 ----
        scene.rootNode.addChildNode(mk(SCNCylinder(radius: 0.32, height: 0.62), shade,
                                       SCNVector3(0, -1.24, 0)))
        scene.rootNode.addChildNode(mk(SCNBox(width: 2.2, height: 0.72, length: 0.95, chamferRadius: 0.32),
                                       NSColor(calibratedRed: 0.33, green: 0.42, blue: 0.60, alpha: 1),
                                       SCNVector3(0, -2.18, 0)))
        let ring = mk(SCNTorus(ringRadius: 1.95, pipeRadius: 0.012),
                      NSColor(white: 0.5, alpha: 1), SCNVector3(0, -2.45, 0))
        ring.opacity = 0.35
        scene.rootNode.addChildNode(ring)

        // ---- 相机 ----
        let cam = SCNNode(); cam.camera = SCNCamera()
        cam.camera?.projectionDirection = .vertical
        cam.camera?.fieldOfView = 40
        cam.position = SCNVector3(0, -0.55, 5.6)
        scene.rootNode.addChildNode(cam)

        // ---- 灯光:高环境光打底,方向光只给一点体积感 ----
        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient
        amb.light?.intensity = 680
        scene.rootNode.addChildNode(amb)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional
        key.light?.intensity = 260
        key.eulerAngles = SCNVector3(-0.3, 0.35, 0)
        scene.rootNode.addChildNode(key)
    }

    func apply(pitch: Double, yaw: Double, roll: Double) {
        let a = 0.35
        sp += (pitch - sp) * a
        sy += (yaw   - sy) * a
        sr += (roll  - sr) * a
        let k = Double.pi / 180
        head.eulerAngles = SCNVector3(sp * k, sy * k, sr * k)
    }
}

struct HeadView: NSViewRepresentable {
    let engine: HeadScene
    let pitch: Double
    let yaw: Double
    let roll: Double

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = engine.scene
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.allowsCameraControl = false
        v.rendersContinuously = true
        v.isPlaying = true
        return v
    }
    func updateNSView(_ v: SCNView, context: Context) {
        engine.apply(pitch: pitch, yaw: yaw, roll: roll)
    }
}
