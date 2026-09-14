import Foundation

var pass = 0, fail = 0
func check(_ name: String, _ got: Double, _ want: Double, tol: Double) {
    let ok = abs(got - want) <= tol
    print(String(format: "  %@ %-42s 期望 %+7.3f  实测 %+7.3f  (容差 %.3f)",
                 ok ? "✅" : "❌", (name as NSString).utf8String!, want, got, tol))
    ok ? (pass += 1) : (fail += 1)
}

print("########## 1. 斜率还原:无噪声 ##########")
for rate in [0.0, 0.3, 1.5, -2.4, 7.0] {           // °/min
    let pts = (0..<360).map { i -> (Double, Double) in
        let t = Double(i) * 0.5                      // 0.5s 一点,共 3 分钟
        return (t, rate / 60.0 * t)
    }
    check("漂移 \(rate) °/min", lsqSlope(pts) * 60, rate, tol: 1e-9)
}

print("\n########## 2. 斜率还原:叠加陀螺噪声(σ=0.05°) ##########")
srandom(42)
func gauss(_ sd: Double) -> Double {
    let u1 = Double.random(in: 1e-9...1), u2 = Double.random(in: 0...1)
    return sd * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
}
for rate in [0.0, 1.2, -3.5] {
    let pts = (0..<360).map { i -> (Double, Double) in
        let t = Double(i) * 0.5
        return (t, rate / 60.0 * t + gauss(0.05))
    }
    check("含噪 \(rate) °/min", lsqSlope(pts) * 60, rate, tol: 0.05)
}

print("\n########## 3. 数据点太少时不给结论 ##########")
check("只有 2 个点应返回 0", lsqSlope([(0,0),(1,99)]), 0, tol: 0)

print("\n########## 4. 角度解缠绕(±180 跳变) ##########")
let cases: [(Double, Double, Double, String)] = [
    (  10,    5,    5, "常规正向"),
    (   5,   10,   -5, "常规反向"),
    (-175,  175,   10, "跨 +180 → -180"),
    ( 175, -175,  -10, "跨 -180 → +180"),
    ( 179, -179,   -2, "小跨越"),
]
for (cur, prev, want, name) in cases {
    check("\(name)  \(prev)°→\(cur)°", unwrapDelta(cur, prev), want, tol: 1e-9)
}

print("\n########## 5. 端到端:yaw 绕圈一周 + 真实漂移 ##########")
// 模拟 yaw 以 2.0°/min 漂移,穿过 ±180 边界多次
var acc = 0.0, prevRaw = 0.0
var samples: [(Double, Double)] = []
for i in 0..<720 {                                  // 6 分钟
    let t = Double(i) * 0.5
    let trueAngle = 2.0 / 60.0 * t + 170            // 从 170° 起,会越过 180
    var raw = trueAngle.truncatingRemainder(dividingBy: 360)
    if raw > 180 { raw -= 360 }                     // 折回 ±180
    if i == 0 { prevRaw = raw }
    acc += unwrapDelta(raw, prevRaw); prevRaw = raw
    samples.append((t, acc))
}
check("跨边界后仍能还原 2.0 °/min", lsqSlope(samples) * 60, 2.0, tol: 1e-6)

print("\n" + String(repeating: "=", count: 60))
print(fail == 0 ? "✅ 全部 \(pass) 项通过" : "❌ \(fail) 项失败 / 共 \(pass+fail) 项")
exit(fail == 0 ? 0 : 1)
