import SwiftUI

// MARK: - 漂移测量

struct DriftChart: View {
    let samples: [DriftSample]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let series: [(String, Color, (DriftSample) -> Double)] = [
                ("P", .orange, { $0.p }), ("R", .green, { $0.r }), ("Y", .cyan, { $0.y })
            ]
            let all = samples.flatMap { [$0.p, $0.r, $0.y] }
            let lo = min(all.min() ?? -1, -0.5), hi = max(all.max() ?? 1, 0.5)
            let span = max(hi - lo, 1.0)
            let tMax = max(samples.last?.t ?? 1, 1)

            ZStack {
                // 零线
                Path { p in
                    let y = h - CGFloat((0 - lo) / span) * h
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
                .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                ForEach(series.indices, id: \.self) { i in
                    let (_, color, get) = series[i]
                    Path { path in
                        for (j, s) in samples.enumerated() {
                            let x = CGFloat(s.t / tMax) * w
                            let y = h - CGFloat((get(s) - lo) / span) * h
                            j == 0 ? path.move(to: CGPoint(x: x, y: y))
                                   : path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(color, lineWidth: 1.6)
                }
            }
        }
    }
}

struct DriftOverlay: View {
    @ObservedObject var m: MotionModel

    private func row(_ label: String, _ color: Color, _ cur: Double,
                     _ rate: Double, control: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 56, alignment: .leading)
            if control {
                Text("对照").font(.system(size: 9))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text("被测").font(.system(size: 9))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.35), in: Capsule())
                    .foregroundStyle(.white)
            }
            Text(String(format: "%+6.2f°", cur))
                .font(.system(size: 12, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Text(m.driftSamples.count >= 6 ? String(format: "%+6.2f °/min", rate) : "统计中…")
                .font(.system(size: 13, weight: .semibold, design: .monospaced)).monospacedDigit()
                .foregroundStyle(control ? .white.opacity(0.7)
                                         : (abs(rate) < 0.3 ? .green : .cyan))
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.80))
            VStack(spacing: 11) {
                if !m.driftActive {
                    Image(systemName: "hourglass")
                        .font(.system(size: 32, weight: .semibold)).foregroundStyle(Color.accentColor)
                    Text("陀螺仪零偏测量").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("戴着耳机，坐正，尽量别动头。")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    Text("不能摘下来放桌上 —— 皮肤检测一旦判定「不在耳中」，\n运动数据流会直接断掉，测不到任何东西。")
                        .font(.caption).foregroundStyle(.orange.opacity(0.85))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Text("俯仰和侧倾有重力锚定、不会漂，所以它们的变化量就是\n你头部真实移动的量级 —— 相当于自带一组对照实验。")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("开始测量") { m.startDrift() }.buttonStyle(.borderedProminent)
                        Button("关闭") { m.closeDrift() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    HStack {
                        Circle().fill(m.driftStalled ? .red
                                      : (m.driftDisturbed ? .orange : .green))
                            .frame(width: 7, height: 7)
                        Text(m.driftStalled ? "数据流已中断"
                             : (m.driftDisturbed ? "检测到大幅晃动" : "测量中"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(m.driftStalled ? .red
                                             : (m.driftDisturbed ? .orange : .green))
                        Spacer()
                        Text(String(format: "%d:%02d · %d 点%@",
                                    Int(m.driftElapsed) / 60, Int(m.driftElapsed) % 60,
                                    m.driftSamples.count,
                                    m.driftStalls > 0 ? " · 断流 \(m.driftStalls) 次" : ""))
                            .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                    }

                    if m.driftStalled {
                        Text("耳机停止上报数据了。多半是被摘下、进了休眠，或蓝牙掉了。\n戴回耳朵上就会自动恢复，中断这段时间不计入统计。")
                            .font(.caption2).foregroundStyle(.red.opacity(0.9))
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 2)
                    }

                    DriftChart(samples: m.driftSamples)
                        .frame(height: 84)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .opacity(m.driftStalled ? 0.4 : 1)

                    VStack(spacing: 5) {
                        row("PITCH 俯仰", .orange, m.driftCurP, m.driftRateP, control: true)
                        row("ROLL 侧倾",  .green,  m.driftCurR, m.driftRateR, control: true)
                        row("YAW 偏航",   .cyan,   m.driftCurY, m.driftRateY, control: false)
                    }

                    HStack(spacing: 4) {
                        Text(String(format: "头部晃动幅度 %.1f°", max(m.driftPPp, m.driftPPr)))
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        if m.driftElapsed > 30 {
                            Text(["结果不可信", "还不够静", "结果可信"][m.driftQuality])
                                .font(.caption2)
                                .foregroundStyle([Color.orange, .yellow, .green][m.driftQuality])
                        }
                    }

                    if !m.driftVerdict.isEmpty {
                        Text(m.driftVerdict).font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button("重新开始") { m.startDrift() }.buttonStyle(.bordered)
                        Button("停止") { m.stopDrift() }.buttonStyle(.borderedProminent)
                        Button("关闭") { m.closeDrift() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .padding(16)
        }
    }
}
