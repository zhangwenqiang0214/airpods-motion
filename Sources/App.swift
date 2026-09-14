import SwiftUI
import SceneKit
import CoreMotion
import AppKit
import os

// MARK: - 校准状态机

enum CalStep: Int, Equatable {
    case idle = 0, center, pitchDown, yawLeft, rollRight, finished

    var index: Int { rawValue }
    var title: String {
        switch self {
        case .center:    return "第 1 步 / 共 4 步 · 设定零点"
        case .pitchDown: return "第 2 步 / 共 4 步 · 俯仰轴"
        case .yawLeft:   return "第 3 步 / 共 4 步 · 偏航轴"
        case .rollRight: return "第 4 步 / 共 4 步 · 侧倾轴"
        case .finished:  return "校准完成"
        case .idle:      return ""
        }
    }
    /// 准备阶段:告诉你待会儿要做什么
    var brief: String {
        switch self {
        case .center:    return "坐正，看向屏幕正前方"
        case .pitchDown: return "待会儿请慢慢低头，看向键盘"
        case .yawLeft:   return "待会儿请慢慢把头转向左边"
        case .rollRight: return "待会儿请把头歪向右肩"
        case .finished:  return "零点和三个轴向都已确定"
        case .idle:      return ""
        }
    }
    var briefDetail: String {
        switch self {
        case .center:    return "点「开始」后有 3 秒倒计时，\n倒计时结束那一刻的朝向会被记为零点。"
        case .pitchDown: return "程序会观察俯仰角往哪个方向变化，\n据此判定这个轴的正负。"
        case .yawLeft:   return "转头就好，身体不用跟着转。"
        case .rollRight: return "耳朵往肩膀方向倒，\n不是转头、也不是低头。"
        default:         return ""
        }
    }
    /// 执行阶段:正在做的动作
    var action: String {
        switch self {
        case .center:    return "保持不动"
        case .pitchDown: return "慢慢低头"
        case .yawLeft:   return "慢慢向左转头"
        case .rollRight: return "头歪向右肩"
        default:         return ""
        }
    }
    var symbol: String {
        switch self {
        case .center:    return "figure.seated.side"
        case .pitchDown: return "arrow.down"
        case .yawLeft:   return "arrow.left"
        case .rollRight: return "arrow.clockwise"
        case .finished:  return "checkmark.seal.fill"
        case .idle:      return ""
        }
    }
    var next: CalStep {
        switch self {
        case .center:    return .pitchDown
        case .pitchDown: return .yawLeft
        case .yawLeft:   return .rollRight
        case .rollRight: return .finished
        default:         return .idle
        }
    }
}

enum CalPhase { case ready, running, confirmed }

// MARK: - 数据模型

final class MotionModel: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    static let shared = MotionModel()
    private let mgr = CMHeadphoneMotionManager()

    @Published var authStatus: CMAuthorizationStatus = .notDetermined
    @Published var available = false
    @Published var running   = false
    @Published var frames    = 0
    @Published var hz        = 0.0
    @Published var errorText: String?
    @Published var streamStalled = false
    @Published var lastFrameAgo = 0.0
    @Published var reconnects = 0

    private let logr = Logger(subsystem: "local.tools.airpodsmotion", category: "motion")
    private var lastFrameAt: Date?
    private var streamWatchdog: Timer?
    private var lastRestart = Date.distantPast
    private var retryBackoff = 20.0
    private var startedAt = Date()

    @Published var pitch = 0.0
    @Published var roll  = 0.0
    @Published var yaw   = 0.0
    @Published var ax = 0.0
    @Published var ay = 0.0
    @Published var az = 0.0
    @Published var gx = 0.0
    @Published var gy = 0.0
    @Published var gz = 0.0

    // 漂移测量
    @Published var driftOpen = false
    @Published var driftActive = false
    @Published var driftDisturbed = false
    @Published var driftElapsed = 0.0
    @Published var driftSamples: [DriftSample] = []
    @Published var driftCurP = 0.0
    @Published var driftCurR = 0.0
    @Published var driftCurY = 0.0
    @Published var driftRateP = 0.0
    @Published var driftRateR = 0.0
    @Published var driftRateY = 0.0
    @Published var driftVerdict = ""

    @Published var driftStalled = false
    @Published var driftStalls = 0
    @Published var driftPPp = 0.0
    @Published var driftPPr = 0.0
    @Published var driftQuality = 0

    private var driftLastFrame = Date()
    private var driftLastSample = Date.distantPast
    private var driftBase: (Double, Double, Double)?
    private var driftPrevRaw: (Double, Double, Double) = (0, 0, 0)
    private var driftAcc: (Double, Double, Double) = (0, 0, 0)
    private var driftWatchdog: Timer?

    // 校准
    @Published var step: CalStep = .idle
    @Published var phase: CalPhase = .ready
    @Published var countdown = 0
    @Published var progress  = 0.0
    @Published var holding   = false
    @Published var measured  = 0.0
    @Published var zeroed = false
    @Published var axesCalibrated = false
    @Published var signP = 1.0
    @Published var signY = 1.0
    @Published var signR = 1.0

    private var reference: CMAttitude?
    private var lastRaw: CMAttitude?
    private var timer: Timer?
    private var holdStart: Date?
    private let threshold = 15.0     // 度
    private let holdSecs  = 0.8      // 需要保持住的时间

    private var windowStart = Date()
    private var windowFrames = 0

    private override init() {
        super.init()
        mgr.delegate = self
        let d = UserDefaults.standard
        if d.bool(forKey: "axesCalibrated") {
            axesCalibrated = true
            signP = d.double(forKey: "signP")
            signY = d.double(forKey: "signY")
            signR = d.double(forKey: "signR")
            // v1 的俯仰轴判据是反的,迁移时翻一次,不用重新校准
            if d.integer(forKey: "calVersion") < 2 {
                signP = -signP
                d.set(signP, forKey: "signP")
                d.set(2, forKey: "calVersion")
            }
        }
        refreshStatus()
    }

    deinit { shutdown() }

    /// 退出前必须调用:否则 CoreMotion 还会往主队列投递回调,
    /// 而此时对象已在析构 → EXC_BAD_ACCESS
    func shutdown() {
        timer?.invalidate(); timer = nil
        streamWatchdog?.invalidate(); streamWatchdog = nil
        mgr.stopDeviceMotionUpdates()
        mgr.stopConnectionStatusUpdates()
        mgr.delegate = nil
        running = false
    }

    func refreshStatus() {
        authStatus = CMHeadphoneMotionManager.authorizationStatus()
        available  = mgr.isDeviceMotionAvailable
    }

    func start() {
        guard !running else { return }
        errorText = nil
        frames = 0; windowFrames = 0; windowStart = Date()
        lastFrameAt = nil; streamStalled = false; reconnects = 0
        lastRestart = Date(); startedAt = Date(); retryBackoff = 20.0
        running = true
        logr.notice("start: available=\(self.mgr.isDeviceMotionAvailable, privacy: .public) auth=\(CMHeadphoneMotionManager.authorizationStatus().rawValue, privacy: .public)")
        beginUpdates()

        // 看门狗:CoreMotion 在耳机离线后不会自己恢复,必须主动重启数据流
        streamWatchdog?.invalidate()
        streamWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            let ago = Date().timeIntervalSince(self.lastFrameAt ?? self.startedAt)
            self.lastFrameAgo = ago

            // 首帧宽限 20 秒:AirPods 头部追踪启动本身要好几秒,
            // 之前每 5 秒就重建一次,等于在它吐出第一帧前反复掐死它。
            let grace = self.lastFrameAt == nil ? 20.0 : 10.0
            guard ago > grace else { self.streamStalled = false; return }
            self.streamStalled = true

            guard Date().timeIntervalSince(self.lastRestart) > self.retryBackoff else { return }
            self.logr.notice("等待超时 \(ago, format: .fixed(precision: 1), privacy: .public)s, available=\(self.mgr.isDeviceMotionAvailable, privacy: .public) active=\(self.mgr.isDeviceMotionActive, privacy: .public)")
            self.reconnect()
            self.retryBackoff = min(self.retryBackoff * 1.6, 90.0)   // 退避,不再疯狂重试
        }
        refreshStatus()
    }

    /// 手动/自动重连数据流
    func reconnect() {
        guard running else { return }
        lastRestart = Date()
        reconnects += 1
        logr.notice("reconnect #\(self.reconnects, privacy: .public) available=\(self.mgr.isDeviceMotionAvailable, privacy: .public)")
        mgr.stopDeviceMotionUpdates()
        beginUpdates()
        logr.notice("重连后 active=\(self.mgr.isDeviceMotionActive, privacy: .public)")
        refreshStatus()
    }

    private func beginUpdates() {
        mgr.startConnectionStatusUpdates()
        mgr.startDeviceMotionUpdates(to: .main) { [weak self] md, err in
            guard let self else { return }
            if let err {
                self.errorText = err.localizedDescription
                self.logr.error("motion error: \(err.localizedDescription, privacy: .public)")
                return
            }
            guard let d = md else { return }

            if self.lastFrameAt == nil {
                self.logr.notice("✅ 首帧到达,启动耗时 \(Date().timeIntervalSince(self.startedAt), format: .fixed(precision: 1), privacy: .public)s")
                self.retryBackoff = 20.0
            }
            self.lastFrameAt = Date()
            self.streamStalled = false
            self.lastFrameAgo = 0

            self.lastRaw = d.attitude.copy() as? CMAttitude
            let att = (d.attitude.copy() as? CMAttitude) ?? d.attitude
            if let ref = self.reference { att.multiply(byInverseOf: ref) }

            let r = 180.0 / Double.pi
            self.pitch = att.pitch * r
            self.roll  = att.roll  * r
            self.yaw   = att.yaw   * r
            self.ax = d.userAcceleration.x
            self.ay = d.userAcceleration.y
            self.az = d.userAcceleration.z
            self.gx = d.rotationRate.x
            self.gy = d.rotationRate.y
            self.gz = d.rotationRate.z

            self.frames += 1; self.windowFrames += 1
            let dt = Date().timeIntervalSince(self.windowStart)
            if dt >= 1.0 {
                self.hz = Double(self.windowFrames) / dt
                self.windowFrames = 0; self.windowStart = Date()
            }
            self.tick()
            self.driftTick(d)
        }
    }

    func stop() {
        guard running else { return }
        streamWatchdog?.invalidate(); streamWatchdog = nil
        mgr.stopDeviceMotionUpdates()
        mgr.stopConnectionStatusUpdates()
        cancel()
        stopDrift()
        running = false; hz = 0; streamStalled = false
        logr.notice("stop: 共 \(self.frames, privacy: .public) 帧, 重连 \(self.reconnects, privacy: .public) 次")
    }

    // MARK: 引导流程 —— 每一步都要手动点，程序不自己往前跑

    func startGuided() {
        guard running, step == .idle else { return }
        step = .center; phase = .ready
    }

    func quickZero() {
        guard running, step == .idle else { return }
        step = .center; phase = .ready; zeroOnly = true
    }

    private var zeroOnly = false

    /// 准备 → 执行
    func beginStep() {
        guard phase == .ready else { return }
        phase = .running
        progress = 0; holding = false; holdStart = nil; measured = 0
        if step == .center {
            countdown = 3
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                guard let self, self.step == .center, self.phase == .running else { t.invalidate(); return }
                if self.countdown <= 1 {
                    t.invalidate(); self.timer = nil
                    self.reference = self.lastRaw?.copy() as? CMAttitude
                    self.zeroed = self.reference != nil
                    self.phase = .confirmed
                } else {
                    self.countdown -= 1
                }
            }
        }
    }

    /// 确认 → 下一步
    func nextStep() {
        guard phase == .confirmed else { return }
        if zeroOnly { zeroOnly = false; finish(); return }
        if step == .rollRight {
            axesCalibrated = true
            let d = UserDefaults.standard
            d.set(true, forKey: "axesCalibrated")
            d.set(signP, forKey: "signP")
            d.set(signY, forKey: "signY")
            d.set(signR, forKey: "signR")
            d.set(2, forKey: "calVersion")
            step = .finished; phase = .confirmed
        } else if step == .finished {
            finish()
        } else {
            step = step.next; phase = .ready
        }
    }

    func redoStep() {
        phase = .ready
        progress = 0; holding = false; holdStart = nil; measured = 0
    }

    func skipStep() {
        guard step != .center, step != .finished else { return }
        measured = 0
        phase = .confirmed
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        step = .idle; phase = .ready
        progress = 0; holding = false; countdown = 0
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        zeroOnly = false
        step = .idle; phase = .ready
        progress = 0; holding = false; holdStart = nil; countdown = 0
    }

    /// 动作检测:先把幅度做到位,再保持住 0.8 秒
    private func tick() {
        guard phase == .running else { return }
        let v: Double
        switch step {
        case .pitchDown: v = pitch
        case .yawLeft:   v = yaw
        case .rollRight: v = roll
        default: return
        }

        if abs(v) >= threshold {
            if holdStart == nil { holdStart = Date() }
            holding = true
            let held = Date().timeIntervalSince(holdStart!)
            progress = 0.5 + min(1.0, held / holdSecs) * 0.5
            if held >= holdSecs {
                measured = v
                // SceneKit 右手系推导:
                //   绕 +X 正转 → 脸法向量 (0,0,1) 变 (0,-sinθ,cosθ) → 脸朝下。低头要 euler.x > 0
                //   绕 +Y 正转 → 脸法向量转向 +X(屏幕右)。左转头要 euler.y < 0
                //   绕 +Z 正转 → 头顶转向 -X(屏幕左)。歪向右肩要 euler.z < 0
                switch step {
                case .pitchDown: signP = v < 0 ? -1.0 : 1.0
                case .yawLeft:   signY = v < 0 ?  1.0 : -1.0
                case .rollRight: signR = v < 0 ?  1.0 : -1.0
                default: break
                }
                holding = false; holdStart = nil; progress = 1.0
                phase = .confirmed
            }
        } else {
            if abs(v) < threshold * 0.8 { holdStart = nil; holding = false }
            progress = min(0.5, abs(v) / threshold * 0.5)
        }
    }

    // MARK: 漂移测量

    func openDrift()  { guard running else { return }; driftOpen = true; driftActive = false }
    func closeDrift() { driftOpen = false; stopDrift() }

    func stopDrift() {
        driftActive = false
        driftWatchdog?.invalidate(); driftWatchdog = nil
        driftStalled = false
    }

    func startDrift() {
        guard running else { return }
        driftOpen = true
        driftActive = true
        driftDisturbed = false
        driftStalled = false
        driftStalls = 0
        driftElapsed = 0
        driftSamples = []
        driftBase = nil
        driftAcc = (0, 0, 0)
        driftPrevRaw = (pitch, roll, yaw)
        driftLastFrame = Date()
        driftLastSample = .distantPast
        driftCurP = 0; driftCurR = 0; driftCurY = 0
        driftRateP = 0; driftRateR = 0; driftRateY = 0
        driftPPp = 0; driftPPr = 0; driftQuality = 0
        driftVerdict = ""

        // 看门狗:数据流断了要立刻告诉用户,而不是让界面静止在旧数字上
        driftWatchdog?.invalidate()
        driftWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.driftActive else { return }
            let gap = Date().timeIntervalSince(self.driftLastFrame)
            let nowStalled = gap > 2.0
            if nowStalled && !self.driftStalled { self.driftStalls += 1 }
            self.driftStalled = nowStalled
        }
    }

    private func driftTick(_ d: CMDeviceMotion) {
        guard driftActive else { return }

        // 只累计真实有数据的时间。断流那段不计入,否则 t 轴被拉长,斜率被稀释。
        let now = Date()
        let dt = now.timeIntervalSince(driftLastFrame)
        driftLastFrame = now
        if dt < 1.0 { driftElapsed += dt }

        // 扰动检测
        let w = sqrt(d.rotationRate.x*d.rotationRate.x + d.rotationRate.y*d.rotationRate.y
                   + d.rotationRate.z*d.rotationRate.z)
        let a = sqrt(d.userAcceleration.x*d.userAcceleration.x + d.userAcceleration.y*d.userAcceleration.y
                   + d.userAcceleration.z*d.userAcceleration.z)
        if w > 0.35 || a > 0.12 { driftDisturbed = true }

        driftAcc.0 += unwrapDelta(pitch, driftPrevRaw.0)
        driftAcc.1 += unwrapDelta(roll,  driftPrevRaw.1)
        driftAcc.2 += unwrapDelta(yaw,   driftPrevRaw.2)
        driftPrevRaw = (pitch, roll, yaw)

        if driftBase == nil, driftElapsed > 2.0 { driftBase = driftAcc }
        guard let base = driftBase else { return }

        driftCurP = driftAcc.0 - base.0
        driftCurR = driftAcc.1 - base.1
        driftCurY = driftAcc.2 - base.2

        guard now.timeIntervalSince(driftLastSample) >= 0.5 else { return }
        driftLastSample = now
        driftSamples.append(DriftSample(t: driftElapsed, p: driftCurP, r: driftCurR, y: driftCurY))
        if driftSamples.count > 2400 { driftSamples.removeFirst() }

        driftRateP = lsqSlope(driftSamples.map { ($0.t, $0.p) }) * 60
        driftRateR = lsqSlope(driftSamples.map { ($0.t, $0.r) }) * 60
        driftRateY = lsqSlope(driftSamples.map { ($0.t, $0.y) }) * 60

        // pitch/roll 是对照组:它们有重力锚定不会漂,
        // 所以它们的变化量就是「你的头实际动了多少」。
        let ps = driftSamples.map { $0.p }, rs = driftSamples.map { $0.r }
        driftPPp = (ps.max() ?? 0) - (ps.min() ?? 0)
        driftPPr = (rs.max() ?? 0) - (rs.min() ?? 0)

        guard driftElapsed > 30 else { return }
        let head = max(abs(driftRateP), abs(driftRateR))   // 头部真实漂移量级
        let yawR = abs(driftRateY)
        let pp   = max(driftPPp, driftPPr)                 // 头部抖动幅度

        if pp > 4.0 {
            driftQuality = 0
            driftVerdict = String(format: "头部晃动 %.1f°,太大了。坐正、找个头靠,重新测。", pp)
        } else if yawR > head * 3 && yawR > 0.3 {
            driftQuality = 2
            driftVerdict = String(format:
                "对照组(俯仰/侧倾,重力锚定)只漂 %.2f °/min,\n偏航漂 %.2f °/min —— 约 %.0f 倍,这是陀螺仪零偏。",
                head, yawR, yawR / max(head, 0.01))
        } else {
            driftQuality = 1
            driftVerdict = String(format:
                "偏航 %.2f °/min 与对照组 %.2f °/min 接近,\n说明主要是你的头在动,零偏被淹没了。再静一会儿。",
                yawR, head)
        }
    }

    func resetAll() {
        reference = nil; zeroed = false; axesCalibrated = false
        signP = 1; signY = 1; signR = 1
        let d = UserDefaults.standard
        d.removeObject(forKey: "axesCalibrated")
        d.removeObject(forKey: "signP")
        d.removeObject(forKey: "signY")
        d.removeObject(forKey: "signR")
        cancel()
    }

    func headphoneMotionManagerDidConnect(_ m: CMHeadphoneMotionManager) {
        logr.notice("耳机已连接")
        refreshStatus()
        // 去抖:刚重连过就别再来一次,否则和看门狗互相打架
        if running, Date().timeIntervalSince(lastRestart) > 10 { reconnect() }
    }

    func headphoneMotionManagerDidDisconnect(_ m: CMHeadphoneMotionManager) {
        logr.notice("耳机已断开")
        refreshStatus()
    }
}

// MARK: - 界面

struct Readout: View {
    let label: String, value: Double, unit: String, fmt: String
    var body: some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(String(format: fmt, value))
                .font(.system(size: 16, weight: .semibold, design: .monospaced)).monospacedDigit()
            Text(unit).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CalibrationOverlay: View {
    @ObservedObject var m: MotionModel

    private var stepDots: some View {
        HStack(spacing: 7) {
            ForEach(1...4, id: \.self) { i in
                Circle()
                    .fill(i < m.step.index ? Color.accentColor
                          : i == m.step.index ? Color.accentColor
                          : Color.white.opacity(0.25))
                    .frame(width: i == m.step.index ? 9 : 7,
                           height: i == m.step.index ? 9 : 7)
            }
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.72))
            VStack(spacing: 14) {
                if m.step != .finished { stepDots }
                Text(m.step.title).font(.caption).foregroundStyle(.white.opacity(0.65))

                Image(systemName: m.step.symbol)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(m.step == .finished ? Color.green : Color.accentColor)

                switch m.phase {
                case .ready:
                    VStack(spacing: 8) {
                        Text(m.step.brief)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        if !m.step.briefDetail.isEmpty {
                            Text(m.step.briefDetail)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("开始这一步") { m.beginStep() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: [])
                        if m.step != .center {
                            Button("跳过") { m.skipStep() }
                                .buttonStyle(.plain).font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }

                case .running:
                    Text(m.step.action)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                    if m.step == .center {
                        Text("\(m.countdown)")
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .foregroundStyle(.white).monospacedDigit()
                    } else {
                        VStack(spacing: 6) {
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.2)).frame(width: 200, height: 8)
                                Capsule().fill(m.holding ? Color.green : Color.accentColor)
                                    .frame(width: 200 * m.progress, height: 8)
                            }
                            .animation(.linear(duration: 0.08), value: m.progress)
                            Text(m.holding ? "保持住…" : "幅度还不够，继续")
                                .font(.caption)
                                .foregroundStyle(m.holding ? .green : .white.opacity(0.6))
                        }
                    }

                case .confirmed:
                    VStack(spacing: 6) {
                        if m.step == .finished {
                            Text(m.step.brief)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(String(format: "轴向符号  P%+.0f   Y%+.0f   R%+.0f",
                                        m.signP, m.signY, m.signR))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        } else if m.step == .center {
                            Label("零点已记录", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.green)
                            Text("现在所有角度都以这个朝向为 0")
                                .font(.caption).foregroundStyle(.white.opacity(0.6))
                        } else {
                            Label("检测到动作", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.green)
                            Text(m.measured == 0
                                 ? "已跳过，这个轴保持原符号"
                                 : String(format: "实测 %+.1f° → 方向已记录", m.measured))
                                .font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    HStack(spacing: 10) {
                        Button(m.step == .finished ? "完成" : "下一步") { m.nextStep() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: [])
                        if m.step != .finished {
                            Button("重做这一步") { m.redoStep() }
                                .buttonStyle(.plain).font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }

                if m.step != .finished {
                    Button("退出校准") { m.cancel() }
                        .buttonStyle(.plain).font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .padding(22)
        }
    }
}

struct ContentView: View {
    @ObservedObject private var m = MotionModel.shared
    @State private var engine = HeadScene()

    private var authLabel: (String, Color) {
        switch m.authStatus {
        case .authorized:    return ("已授权", .green)
        case .denied:        return ("已拒绝 — 去 系统设置 › 隐私与安全性 › 运动与健身 打开", .red)
        case .restricted:    return ("被策略限制", .orange)
        case .notDetermined: return ("尚未询问 — 点「开始」会弹授权框", .secondary)
        @unknown default:    return ("未知", .secondary)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(m.running ? .green : .gray).frame(width: 8, height: 8)
                Text(m.running ? "采集中" : "已停止").font(.headline)
                if m.running {
                    Text(String(format: "%.0f Hz · %d 帧", m.hz, m.frames))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                if m.running && m.streamStalled {
                    Label(String(format: m.frames == 0 ? "等待首帧 %.0fs" : "数据流中断 %.0fs", m.lastFrameAgo),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    if m.reconnects > 0 {
                        Text("已重连 \(m.reconnects) 次").font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("立即重连") { m.reconnect() }.controlSize(.small)
                }
                Button(m.running ? "停止" : "开始") { m.running ? m.stop() : m.start() }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04))
                HeadView(engine: engine,
                         pitch: m.pitch * m.signP,
                         yaw:   m.yaw   * m.signY,
                         roll:  m.roll  * m.signR)
                    .padding(4)
                if m.step != .idle { CalibrationOverlay(m: m) }
                else if m.driftOpen { DriftOverlay(m: m) }
            }
            .frame(height: 320)

            HStack(spacing: 8) {
                Button { m.startGuided() } label: { Label("引导校准", systemImage: "scope") }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!m.running || m.step != .idle)
                Button { m.quickZero() } label: { Label("重设零点", systemImage: "target") }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!m.running || m.step != .idle)
                Button { m.driftOpen ? m.closeDrift() : m.openDrift() } label: {
                    Label("漂移测量", systemImage: "chart.line.downtrend.xyaxis")
                }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!m.running || m.step != .idle)
                Spacer()
                Button("清除") { m.resetAll() }
                    .buttonStyle(.link).font(.caption)
                    .disabled(!m.zeroed && !m.axesCalibrated)
            }

            HStack(spacing: 14) {
                Label(m.zeroed ? "零点已设" : "零点未设",
                      systemImage: m.zeroed ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(m.zeroed ? .green : .secondary)
                Label(m.axesCalibrated ? "轴向已校准" : "轴向未校准",
                      systemImage: m.axesCalibrated ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(m.axesCalibrated ? .green : .secondary)
                if m.axesCalibrated {
                    Text(String(format: "P%+.0f Y%+.0f R%+.0f", m.signP, m.signY, m.signR))
                        .foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer()
            }
            .font(.caption)

            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    Readout(label: "PITCH 俯仰", value: m.pitch, unit: "度", fmt: "%+.1f")
                    Readout(label: "ROLL 侧倾",  value: m.roll,  unit: "度", fmt: "%+.1f")
                    Readout(label: "YAW 偏航",   value: m.yaw,   unit: "度", fmt: "%+.1f")
                }
                Text("用户加速度(已扣除重力)").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    Readout(label: "X", value: m.ax, unit: "G", fmt: "%+.3f")
                    Readout(label: "Y", value: m.ay, unit: "G", fmt: "%+.3f")
                    Readout(label: "Z", value: m.az, unit: "G", fmt: "%+.3f")
                }
                Text("角速度").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    Readout(label: "X", value: m.gx, unit: "rad/s", fmt: "%+.2f")
                    Readout(label: "Y", value: m.gy, unit: "rad/s", fmt: "%+.2f")
                    Readout(label: "Z", value: m.gz, unit: "rad/s", fmt: "%+.2f")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack { Text("授权状态").foregroundStyle(.secondary); Text(authLabel.0).foregroundStyle(authLabel.1) }
                HStack {
                    Text("耳机运动可用").foregroundStyle(.secondary)
                    Text(m.available ? "是" : "否 — 需连接支持头部追踪的 AirPods")
                        .foregroundStyle(m.available ? .green : .orange)
                }
                if let e = m.errorText { Text("错误:\(e)").foregroundStyle(.red) }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .onAppear { m.refreshStatus() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MotionModel.shared.shutdown()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AirPodsMotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("AirPods 头部姿态") {
            ContentView().frame(minWidth: 460, minHeight: 860)
        }
        .windowResizability(.contentMinSize)
    }
}
