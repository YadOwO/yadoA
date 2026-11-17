import CoreGraphics
import Foundation

// MARK: - 部位与颜色

/// 线条头像的部位槽位。
///
/// 每个头像都按这套槽位排线：换头像时同一槽位的线互相变形（耳朵变耳朵、眼睛变眼睛），
/// 线条不会满屏乱飞。用不到的槽位留空，变形时那条线会缩成一点消失。
/// 原始值决定绘制顺序和变形时的先后错开顺序。
nonisolated enum LineAvatarSlot: Int, CaseIterable, Sendable {
    /// 脸的轮廓。
    case outline
    /// 左耳；也可以是头顶的芽、呆毛等左侧装饰。
    case leftEar
    /// 右耳；也可以是右侧的叶子、呆毛等。
    case rightEar
    /// 左眼。
    case leftEye
    /// 右眼。
    case rightEye
    /// 鼻子或喙。
    case nose
    /// 嘴。
    case mouth
    /// 左侧细节：腮红、胡须、眼圈、内耳线、口鼻部等。
    case leftDetail
    /// 右侧细节，与 `leftDetail` 对应。
    case rightDetail
    /// 额外点缀，如小狗的舌头。
    case accent
}

/// 线条颜色。
nonisolated enum LineAvatarTint: Sendable {
    /// 墨色，跟随系统主文字色，深色外观下自动反色。
    case ink
    /// 账本红，用于鼻子、腮红等点缀。
    case accent
}

/// 设计稿中的一条线：SVG 路径和颜色。直接写字符串时为墨色，用 `.accent(_:)` 写红色。
nonisolated struct LineAvatarStrokeSpec: ExpressibleByStringLiteral, Sendable {
    /// 100×100 设计画布上的 SVG 路径，必须一笔画完。
    let path: String
    /// 线条颜色。
    let tint: LineAvatarTint

    init(path: String, tint: LineAvatarTint) {
        self.path = path
        self.tint = tint
    }

    init(stringLiteral value: String) {
        self.init(path: value, tint: .ink)
    }

    /// 红色点缀线。
    static func accent(_ path: String) -> LineAvatarStrokeSpec {
        LineAvatarStrokeSpec(path: path, tint: .accent)
    }
}

// MARK: - 取样后的线条画面

/// 取样后的一条线，点数固定为 `LineAvatarGeometry.pointCount`。
nonisolated struct LineAvatarStroke: Equatable, Sendable {
    /// 设计画布上按弧长均匀分布的点。
    var points: [CGPoint]
    /// 是否闭合；闭合的线变形前会尝试换起点以减少绕圈。
    var isClosed: Bool
    /// 线条颜色。
    var tint: LineAvatarTint

    /// 由设计稿生成一条线。
    init(spec: LineAvatarStrokeSpec) {
        let polyline = LineAvatarGeometry.polyline(fromSVGPath: spec.path)
        points = LineAvatarGeometry.resample(polyline)
        isClosed = LineAvatarGeometry.isClosed(polyline)
        tint = spec.tint
    }

    init(points: [CGPoint], isClosed: Bool, tint: LineAvatarTint) {
        self.points = points
        self.isClosed = isClosed
        self.tint = tint
    }
}

/// 一幅完整的线条画面：每个槽位一条线，或留空。
nonisolated struct LineAvatarFigure: Sendable {
    /// 各槽位的线；没有的槽位不画。
    var strokes: [LineAvatarSlot: LineAvatarStroke]
}

// MARK: - 预制头像

/// 一个预制线条头像。
nonisolated struct LineAvatarPreset: Identifiable, Equatable, Sendable {
    /// 稳定 ID，保存到账号资料后不能再改；新增头像只能追加新 ID。
    let id: String
    /// 各槽位的设计稿。
    let strokes: [LineAvatarSlot: LineAvatarStrokeSpec]

    /// 头像名字的本地化键，如 `lineAvatar.preset.cat`。
    var nameKey: String { "lineAvatar.preset.\(id)" }

    /// 取样后的画面，首次访问时计算并缓存。
    var figure: LineAvatarFigure {
        LineAvatarCatalog.figure(for: self)
    }

    static func == (lhs: LineAvatarPreset, rhs: LineAvatarPreset) -> Bool {
        lhs.id == rhs.id
    }
}

/// 全部预制线条头像。
///
/// 设计约定：画布 100×100，内容大致落在 12...88 之内；线宽 3，眼睛用半径约 1.3 的小圆画成实心点；
/// 每个头像至少有脸的轮廓，红色点缀尽量只用在鼻子、腮红、舌头这类小面积部位。
nonisolated enum LineAvatarCatalog {
    /// 全部预制头像，顺序即开发页里的展示顺序。
    static let presets: [LineAvatarPreset] = [
        // 芽豆：圆豆子顶着一棵芽，红脸蛋。
        LineAvatarPreset(
            id: "bean",
            strokes: [
                .outline: "M50 36.5 C63.8 36.5 75 47 75 60 C75 73 63.8 83.5 50 83.5 C36.2 83.5 25 73 25 60 C25 47 36.2 36.5 50 36.5 Z",
                .leftEar: "M50 36.5 C50 32 50 28 50 25 C45.5 17 37.5 15.5 32.5 17.5 C36.5 25 43.5 27.5 50 25",
                .rightEar: "M50 28 C54.5 20 62.5 17.5 68 19 C64.5 26 57.5 29.5 50 28",
                .leftEye: "M40 55.7 C40.7 55.7 41.3 56.3 41.3 57 C41.3 57.7 40.7 58.3 40 58.3 C39.3 58.3 38.7 57.7 38.7 57 C38.7 56.3 39.3 55.7 40 55.7 Z",
                .rightEye: "M60 55.7 C60.7 55.7 61.3 56.3 61.3 57 C61.3 57.7 60.7 58.3 60 58.3 C59.3 58.3 58.7 57.7 58.7 57 C58.7 56.3 59.3 55.7 60 55.7 Z",
                .mouth: "M45 65 Q50 70 55 65",
                .leftDetail: .accent("M32 62.4 C33.7 62.4 35 63.1 35 64 C35 64.9 33.7 65.6 32 65.6 C30.3 65.6 29 64.9 29 64 C29 63.1 30.3 62.4 32 62.4 Z"),
                .rightDetail: .accent("M68 62.4 C69.7 62.4 71 63.1 71 64 C71 64.9 69.7 65.6 68 65.6 C66.3 65.6 65 64.9 65 64 C65 63.1 66.3 62.4 68 62.4 Z"),
            ]
        ),
        // 小猫：尖耳朵、红鼻子、ω 嘴，两侧胡须。
        LineAvatarPreset(
            id: "cat",
            strokes: [
                .outline: "M50 34 C66.6 34 80 45.2 80 59 C80 72.8 66.6 84 50 84 C33.4 84 20 72.8 20 59 C20 45.2 33.4 34 50 34 Z",
                .leftEar: "M23.5 47.3 L24.9 24 Q25 22 26.3 23.1 L40.7 35.2",
                .rightEar: "M59.3 35.2 L73.7 23.1 Q75 22 75.1 24 L76.5 47.3",
                .leftEye: "M39 55.7 C39.7 55.7 40.3 56.3 40.3 57 C40.3 57.7 39.7 58.3 39 58.3 C38.3 58.3 37.7 57.7 37.7 57 C37.7 56.3 38.3 55.7 39 55.7 Z",
                .rightEye: "M61 55.7 C61.7 55.7 62.3 56.3 62.3 57 C62.3 57.7 61.7 58.3 61 58.3 C60.3 58.3 59.7 57.7 59.7 57 C59.7 56.3 60.3 55.7 61 55.7 Z",
                .nose: .accent("M47.6 63.2 L52.4 63.2 L50 65.6 Z"),
                .mouth: "M44.5 68 Q47.2 71 50 67.6 Q52.8 71 55.5 68",
                .leftDetail: "M12 56 L26 61.5 L13 67",
                .rightDetail: "M88 56 L74 61.5 L87 67",
            ]
        ),
        // 小熊：圆耳朵、口鼻部、红鼻头。
        LineAvatarPreset(
            id: "bear",
            strokes: [
                .outline: "M50 29 C66 29 79 42 79 58 C79 74 66 87 50 87 C34 87 21 74 21 58 C21 42 34 29 50 29 Z",
                .leftEar: "M25 43.3 C21.2 41.7 19 37.7 19.6 33.6 C20.2 29.5 23.6 26.4 27.7 26 C31.8 25.7 35.7 28.2 37 32.1",
                .rightEar: "M63 32.1 C64.3 28.2 68.2 25.7 72.3 26 C76.4 26.4 79.8 29.5 80.4 33.6 C81 37.7 78.8 41.7 75 43.3",
                .leftEye: "M40 51.7 C40.7 51.7 41.3 52.3 41.3 53 C41.3 53.7 40.7 54.3 40 54.3 C39.3 54.3 38.7 53.7 38.7 53 C38.7 52.3 39.3 51.7 40 51.7 Z",
                .rightEye: "M60 51.7 C60.7 51.7 61.3 52.3 61.3 53 C61.3 53.7 60.7 54.3 60 54.3 C59.3 54.3 58.7 53.7 58.7 53 C58.7 52.3 59.3 51.7 60 51.7 Z",
                .nose: .accent("M50 60.8 C51.5 60.8 52.8 61.6 52.8 62.5 C52.8 63.4 51.5 64.2 50 64.2 C48.5 64.2 47.2 63.4 47.2 62.5 C47.2 61.6 48.5 60.8 50 60.8 Z"),
                .mouth: "M45.5 70 Q48.2 72.5 50 68.6 L50 65.5 L50 68.6 Q51.8 72.5 54.5 70",
                .leftDetail: "M50 58 C55.8 58 60.5 61.6 60.5 66 C60.5 70.4 55.8 74 50 74 C44.2 74 39.5 70.4 39.5 66 C39.5 61.6 44.2 58 50 58 Z",
            ]
        ),
        // 兔子：长耳朵带内耳线、红鼻子。
        LineAvatarPreset(
            id: "rabbit",
            strokes: [
                .outline: "M50 42 C64.9 42 77 51.8 77 64 C77 76.2 64.9 86 50 86 C35.1 86 23 76.2 23 64 C23 51.8 35.1 42 50 42 Z",
                .leftEar: "M40.5 43.5 C34 33 31 14 37.5 11 C44 8 48 25 46.5 42.5",
                .rightEar: "M59.5 43.5 C66 33 69 14 62.5 11 C56 8 52 25 53.5 42.5",
                .leftEye: "M40 59.7 C40.7 59.7 41.3 60.3 41.3 61 C41.3 61.7 40.7 62.3 40 62.3 C39.3 62.3 38.7 61.7 38.7 61 C38.7 60.3 39.3 59.7 40 59.7 Z",
                .rightEye: "M60 59.7 C60.7 59.7 61.3 60.3 61.3 61 C61.3 61.7 60.7 62.3 60 62.3 C59.3 62.3 58.7 61.7 58.7 61 C58.7 60.3 59.3 59.7 60 59.7 Z",
                .nose: .accent("M48 66.5 L52 66.5 L50 68.6 Z"),
                .mouth: "M45.8 72 Q48.2 74.5 50 70.6 Q51.8 74.5 54.2 72",
                .leftDetail: "M40.5 33 C38.8 26 38.6 19.5 39.6 16.5",
                .rightDetail: "M59.5 33 C61.2 26 61.4 19.5 60.4 16.5",
            ]
        ),
        // 青蛙：头顶两个眼泡、大嘴、红脸蛋。
        LineAvatarPreset(
            id: "frog",
            strokes: [
                .outline: "M50 45 C68.2 45 83 54 83 65 C83 76 68.2 85 50 85 C31.8 85 17 76 17 65 C17 54 31.8 45 50 45 Z",
                .leftEar: "M30 53.7 C25.3 51.7 22.6 46.7 23.8 41.7 C24.9 36.7 29.4 33.3 34.5 33.5 C39.6 33.8 43.8 37.6 44.4 42.7",
                .rightEar: "M55.6 42.7 C56.2 37.6 60.4 33.8 65.5 33.5 C70.6 33.3 75.1 36.7 76.2 41.7 C77.4 46.7 74.7 51.7 70 53.7",
                .leftEye: "M34 41.9 C34.9 41.9 35.6 42.6 35.6 43.5 C35.6 44.4 34.9 45.1 34 45.1 C33.1 45.1 32.4 44.4 32.4 43.5 C32.4 42.6 33.1 41.9 34 41.9 Z",
                .rightEye: "M66 41.9 C66.9 41.9 67.6 42.6 67.6 43.5 C67.6 44.4 66.9 45.1 66 45.1 C65.1 45.1 64.4 44.4 64.4 43.5 C64.4 42.6 65.1 41.9 66 41.9 Z",
                .mouth: "M33 66 Q50 78 67 66",
                .leftDetail: .accent("M25.5 65.8 C27.2 65.8 28.5 66.6 28.5 67.5 C28.5 68.4 27.2 69.2 25.5 69.2 C23.8 69.2 22.5 68.4 22.5 67.5 C22.5 66.6 23.8 65.8 25.5 65.8 Z"),
                .rightDetail: .accent("M74.5 65.8 C76.2 65.8 77.5 66.6 77.5 67.5 C77.5 68.4 76.2 69.2 74.5 69.2 C72.8 69.2 71.5 68.4 71.5 67.5 C71.5 66.6 72.8 65.8 74.5 65.8 Z"),
            ]
        ),
        // 小鸟：头顶两根呆毛、红喙。
        LineAvatarPreset(
            id: "chick",
            strokes: [
                .outline: "M50 31 C65.5 31 78 43.5 78 59 C78 74.5 65.5 87 50 87 C34.5 87 22 74.5 22 59 C22 43.5 34.5 31 50 31 Z",
                .leftEar: "M49.5 31 C46 24 47 17.5 52.5 18",
                .rightEar: "M51 31 C54 25 59.5 23 62 26.5",
                .leftEye: "M40 54.7 C40.7 54.7 41.3 55.3 41.3 56 C41.3 56.7 40.7 57.3 40 57.3 C39.3 57.3 38.7 56.7 38.7 56 C38.7 55.3 39.3 54.7 40 54.7 Z",
                .rightEye: "M60 54.7 C60.7 54.7 61.3 55.3 61.3 56 C61.3 56.7 60.7 57.3 60 57.3 C59.3 57.3 58.7 56.7 58.7 56 C58.7 55.3 59.3 54.7 60 54.7 Z",
                .nose: .accent("M45.5 63 L50 59.8 L54.5 63 L50 67 Z"),
            ]
        ),
        // 小狗：垂耳、墨色鼻头、红舌头。
        LineAvatarPreset(
            id: "dog",
            strokes: [
                .outline: "M50 32 C63.8 32 75 43.6 75 58 C75 72.4 63.8 84 50 84 C36.2 84 25 72.4 25 58 C25 43.6 36.2 32 50 32 Z",
                .leftEar: "M35 37.5 C25 33 15.5 40 15.5 52 C15.5 62 21 66.5 25.5 63 C28.5 60 27.8 53 27.8 47",
                .rightEar: "M65 37.5 C75 33 84.5 40 84.5 52 C84.5 62 79 66.5 74.5 63 C71.5 60 72.2 53 72.2 47",
                .leftEye: "M41 52.7 C41.7 52.7 42.3 53.3 42.3 54 C42.3 54.7 41.7 55.3 41 55.3 C40.3 55.3 39.7 54.7 39.7 54 C39.7 53.3 40.3 52.7 41 52.7 Z",
                .rightEye: "M59 52.7 C59.7 52.7 60.3 53.3 60.3 54 C60.3 54.7 59.7 55.3 59 55.3 C58.3 55.3 57.7 54.7 57.7 54 C57.7 53.3 58.3 52.7 59 52.7 Z",
                .nose: "M50 59.6 C52 59.6 53.6 60.7 53.6 62 C53.6 63.3 52 64.4 50 64.4 C48 64.4 46.4 63.3 46.4 62 C46.4 60.7 48 59.6 50 59.6 Z",
                .mouth: "M44 68.5 Q47.2 71.8 50 67.8 L50 64.6 L50 67.8 Q52.8 71.8 56 68.5",
                .accent: .accent("M48 70.6 Q48 75.2 50 75.2 Q52 75.2 52 70.6"),
            ]
        ),
        // 熊猫：圆耳、斜眼圈、墨色鼻头。
        LineAvatarPreset(
            id: "panda",
            strokes: [
                .outline: "M50 30 C66 30 79 42.5 79 58 C79 73.5 66 86 50 86 C34 86 21 73.5 21 58 C21 42.5 34 30 50 30 Z",
                .leftEar: "M25.8 42.9 C22.2 41.4 20 37.6 20.6 33.7 C21.2 29.7 24.5 26.8 28.4 26.5 C32.4 26.3 36 28.8 37.1 32.6",
                .rightEar: "M62.9 32.6 C64 28.8 67.6 26.3 71.6 26.5 C75.5 26.8 78.8 29.7 79.4 33.7 C80 37.6 77.8 41.4 74.2 42.9",
                .leftEye: "M39.5 53.7 C40.2 53.7 40.8 54.3 40.8 55 C40.8 55.7 40.2 56.3 39.5 56.3 C38.8 56.3 38.2 55.7 38.2 55 C38.2 54.3 38.8 53.7 39.5 53.7 Z",
                .rightEye: "M60.5 53.7 C61.2 53.7 61.8 54.3 61.8 55 C61.8 55.7 61.2 56.3 60.5 56.3 C59.8 56.3 59.2 55.7 59.2 55 C59.2 54.3 59.8 53.7 60.5 53.7 Z",
                .nose: "M50 61.7 C51.5 61.7 52.8 62.5 52.8 63.5 C52.8 64.5 51.5 65.3 50 65.3 C48.5 65.3 47.2 64.5 47.2 63.5 C47.2 62.5 48.5 61.7 50 61.7 Z",
                .mouth: "M46 69 Q48.3 71.3 50 68.3 L50 65.5 L50 68.3 Q51.7 71.3 54 69",
                .leftDetail: "M43.5 49 C46.2 51.1 46.2 55.7 43.4 59.3 C40.6 62.9 36.1 64.1 33.5 62 C30.8 59.9 30.8 55.3 33.6 51.7 C36.4 48.1 40.9 46.9 43.5 49 Z",
                .rightDetail: "M56.5 49 C59.1 46.9 63.6 48.1 66.4 51.7 C69.2 55.3 69.2 59.9 66.5 62 C63.9 64.1 59.4 62.9 56.6 59.3 C53.8 55.7 53.8 51.1 56.5 49 Z",
            ]
        ),
    ]

    /// 按 ID 查找预制头像。
    static func preset(id: String) -> LineAvatarPreset? {
        presets.first { $0.id == id }
    }

    /// 预制头像取样后的画面缓存，按 ID 索引。
    private static let figures: [String: LineAvatarFigure] = Dictionary(
        presets.map { ($0.id, makeFigure($0)) },
        uniquingKeysWith: { first, _ in first }
    )

    /// 取预制头像的画面；不在目录里的临时头像（如测试数据）即时计算。
    static func figure(for preset: LineAvatarPreset) -> LineAvatarFigure {
        figures[preset.id] ?? makeFigure(preset)
    }

    private static func makeFigure(_ preset: LineAvatarPreset) -> LineAvatarFigure {
        LineAvatarFigure(strokes: preset.strokes.mapValues(LineAvatarStroke.init(spec:)))
    }
}

// MARK: - yado logo

/// 选择头像开场写出的 yado logo：三笔的路径、书写时间，以及每一笔被拆成哪些部位。
///
/// 路径和时间取自 yadoI 启动动画（`yadoI/BrandAssets/yadoI.json` 的前 2 秒）：
/// 先写长波浪线，再写左边的钩，最后写带圈的那笔。每一笔按弧长切成几段，
/// 每段对应一个头像槽位，所以写完的 logo 可以直接“散开”变成头像；带圈那笔的圈正好变成脸的轮廓。
nonisolated enum LineAvatarLogo {
    /// logo 中的一笔。
    nonisolated struct Stroke: Sendable {
        /// 原稿坐标系（`viewBox`）下的 SVG 路径。
        let path: String
        /// 开始书写的时间（秒）。
        let start: TimeInterval
        /// 书写时长（秒）。
        let duration: TimeInterval
        /// 书写进度的缓动曲线。
        let curve: LineAvatarTimingCurve
    }

    /// 某个槽位在 logo 中对应的那一段。
    nonisolated struct Segment: Sendable {
        /// 第几笔（`strokes` 的下标）。
        let strokeIndex: Int
        /// 起点占这一笔全长的比例。
        let from: CGFloat
        /// 终点占这一笔全长的比例。
        let to: CGFloat
    }

    /// logo 原稿尺寸，即设计稿 SVG 的 viewBox。
    static let viewBox = CGSize(width: 412, height: 305)
    /// 原稿笔画宽度，用来换算到画布上与头像同样的线宽。
    static let sourceLineWidth: CGFloat = 16

    /// 三笔按书写顺序排列；时间按 60fps 的关键帧换算：0–60、55–85、90–120 帧。
    static let strokes: [Stroke] = [
        Stroke(
            path: "M12.925 301.968C12.925 301.968 77.5213 106.968 124.726 106.968C171.931 106.968 157.024 226.968 204.229 226.968C251.434 226.968 308.577 1.9682 308.577 1.9682",
            start: 0,
            duration: 1,
            curve: LineAvatarTimingCurve(0.55, 0.06, 0.36, 1)
        ),
        Stroke(
            path: "M7.95612 101.968C7.95612 101.968 17.894 196.968 57.6456 199.468C97.3971 201.968 147.087 164.468 147.087 164.468",
            start: 55.0 / 60,
            duration: 0.5,
            curve: LineAvatarTimingCurve(0.55, 0.06, 1, 1)
        ),
        Stroke(
            path: "M171.931 149.468C171.931 149.468 243.981 111.968 278.764 111.968C308.522 111.968 331.954 118.335 356.831 131.069C358.954 132.156 361.087 133.289 363.236 134.468C389.141 148.687 388.893 184.339 373.174 209.468C357.972 233.769 332.436 240.505 306.093 229.468C265.627 212.514 322.687 160.889 355.782 131.968C356.126 131.668 356.475 131.368 356.831 131.069C374.823 115.927 407.956 101.968 407.956 101.968",
            start: 1.5,
            duration: 0.5,
            curve: LineAvatarTimingCurve(0, 0, 0.36, 1)
        ),
    ]

    /// 各槽位在 logo 中对应的段；`accent` 不在 logo 里，变形时从无到有长出来。
    ///
    /// 带圈那笔的圈从全长的 35.32% 开始、89.32% 回到起点，整段交给脸的轮廓。
    static let segments: [LineAvatarSlot: Segment] = [
        .leftDetail: Segment(strokeIndex: 0, from: 0, to: 0.25),
        .mouth: Segment(strokeIndex: 0, from: 0.25, to: 0.5),
        .nose: Segment(strokeIndex: 0, from: 0.5, to: 0.65),
        .rightEar: Segment(strokeIndex: 0, from: 0.65, to: 1),
        .leftEar: Segment(strokeIndex: 1, from: 0, to: 0.5),
        .leftEye: Segment(strokeIndex: 1, from: 0.5, to: 1),
        .rightDetail: Segment(strokeIndex: 2, from: 0, to: 0.3532),
        .outline: Segment(strokeIndex: 2, from: 0.3532, to: 0.8932),
        .rightEye: Segment(strokeIndex: 2, from: 0.8932, to: 1),
    ]

    /// 整个 logo 写完所需的时间（秒）。
    static var drawDuration: TimeInterval {
        strokes.map { $0.start + $0.duration }.max() ?? 0
    }

    /// 写完的 logo 画面，已缩放并居中到设计画布。
    static let figure: LineAvatarFigure = {
        let scale = LineAvatarGeometry.lineWidth / sourceLineWidth
        let offset = CGPoint(
            x: (LineAvatarGeometry.canvasSize - viewBox.width * scale) / 2,
            y: (LineAvatarGeometry.canvasSize - viewBox.height * scale) / 2
        )
        let polylines = strokes.map { stroke in
            LineAvatarGeometry.polyline(fromSVGPath: stroke.path).map {
                CGPoint(x: offset.x + $0.x * scale, y: offset.y + $0.y * scale)
            }
        }
        return LineAvatarFigure(strokes: segments.mapValues { segment in
            LineAvatarStroke(
                points: LineAvatarGeometry.resample(polylines[segment.strokeIndex], from: segment.from, to: segment.to),
                isClosed: false,
                tint: .ink
            )
        })
    }()

    /// 开始书写后经过 `elapsed` 秒时，某槽位那一段已写出的比例。
    ///
    /// 同一笔的几段按这一笔的整体进度依次写出，看起来仍是连贯的一笔。
    /// - Returns: 0...1；不在 logo 里的槽位恒为 0。
    static func reveal(of slot: LineAvatarSlot, elapsed: TimeInterval) -> CGFloat {
        guard let segment = segments[slot] else { return 0 }
        let stroke = strokes[segment.strokeIndex]
        let linear = min(max((elapsed - stroke.start) / stroke.duration, 0), 1)
        let progress = stroke.curve.value(at: linear)
        let length = segment.to - segment.from
        guard length > 0 else { return 1 }
        return min(max((progress - segment.from) / length, 0), 1)
    }
}

// MARK: - 缓动

/// CSS 风格的三次贝塞尔缓动曲线 `cubic-bezier(x1, y1, x2, y2)`。
nonisolated struct LineAvatarTimingCurve: Sendable {
    let x1: CGFloat
    let y1: CGFloat
    let x2: CGFloat
    let y2: CGFloat

    init(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    /// 时间进度 `x`（0...1）对应的动画进度。
    func value(at x: CGFloat) -> CGFloat {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        // 先用二分法找到曲线参数 s，使 bezierX(s) == x；x 方向单调，40 次足够精确
        var low: CGFloat = 0
        var high: CGFloat = 1
        var s = x
        for _ in 0..<40 {
            s = (low + high) / 2
            if Self.bezier(s, x1, x2) < x { low = s } else { high = s }
        }
        return Self.bezier(s, y1, y2)
    }

    /// 端点为 0 和 1 的一维三次贝塞尔。
    private static func bezier(_ t: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }
}
