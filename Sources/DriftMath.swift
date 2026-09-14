import Foundation

struct DriftSample {
    let t: Double     // 秒
    let p: Double     // 相对基准的偏移(度,已解缠绕)
    let r: Double
    let y: Double
}

/// 最小二乘斜率,返回「单位/秒」
func lsqSlope(_ pts: [(Double, Double)]) -> Double {
    guard pts.count >= 3 else { return 0 }
    let n = Double(pts.count)
    let mx = pts.reduce(0.0) { $0 + $1.0 } / n
    let my = pts.reduce(0.0) { $0 + $1.1 } / n
    var num = 0.0, den = 0.0
    for (x, y) in pts { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
    return den == 0 ? 0 : num / den
}

/// 角度解缠绕:把 ±180 跳变还原成连续增量
func unwrapDelta(_ cur: Double, _ prev: Double) -> Double {
    var d = cur - prev
    if d >  180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}
