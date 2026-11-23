import Charts
import SwiftUI

/// 环形占比图加可点选的图例：分类统计和资产分析共用。
///
/// 默认在圆心写总额；点扇区或图例选中一项后，圆心换成这一项的名称和金额，再点一次图例恢复总额。
/// 图例写出图标、名称和百分比，读屏念出金额和百分比，不靠颜色认类别；大字号下只列总额和图例，不画圆环。
/// 空数据由调用方自己处理，这里假定至少有一个扇区。
struct ShareDonutBreakdown: View {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 图例图标预留宽度随字号缩放，避免辅助功能字号下与名称相互覆盖。
    @ScaledMetric(relativeTo: .caption) private var legendSymbolWidth = 20

    /// 要画的扇区和总额。
    let breakdown: CategoryBreakdownPresentation

    /// 没选中时圆心金额上方的标题，例如「总支出」「资产合计」。
    let totalTitle: String

    /// 各扇区的颜色，由调用方按自己的规则决定；图例的图标用同一个颜色。
    let color: @MainActor (CategoryRankingItem) -> Color

    /// 自动化标识前缀：圆环为 `<前缀>-donut`，圆心为 `<前缀>-total`，图例为 `<前缀>-legend-<id>`。
    let identifierPrefix: String

    /// 点选扇区或图例后展示的一项，空值表示全部。
    @State private var selectedID: String?

    /// Swift Charts 返回的累计占比角度选择值。
    @State private var selectedAngle: Double?

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 18) {
                    totalLabel
                    legend
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        donut
                            .frame(width: 176, height: 220)
                        legend
                            .frame(minWidth: 132)
                    }
                    VStack(spacing: 20) {
                        donut
                            .frame(height: 240)
                        legend
                    }
                }
            }
        }
        // 数据变了以后旧的选中项可能已经不在图里，统一清掉。
        .onChange(of: breakdown) { _, _ in
            selectedAngle = nil
            selectedID = nil
        }
    }

    /// 扇区之间留空隙；占比够大的扇区上叠图标补充颜色编码，点击后圆心显示这一项的金额。
    private var donut: some View {
        Chart(breakdown.segments) { segment in
            SectorMark(
                angle: .value(segment.title, breakdown.share(of: segment)),
                innerRadius: .ratio(0.7),
                outerRadius: .ratio(selectedID == segment.id ? 1 : 0.96),
                angularInset: 2
            )
            .cornerRadius(3)
            .foregroundStyle(color(segment))
            .opacity(selectedID == nil || selectedID == segment.id ? 1 : 0.35)
            .annotation(position: .overlay) {
                if breakdown.share(of: segment) >= 0.08 {
                    Image(systemName: segment.symbolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(segment.title)
            .accessibilityValue(Text(detail(for: segment)))
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: Binding(
            get: { selectedAngle },
            set: { value in
                selectedAngle = value
                selectedID = value.flatMap { breakdown.segment(at: $0)?.id }
            }
        ))
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { value in
                proxy.selectAngleValue(at: proxy.angle(at: value.location))
            }
        }
        .accessibilityIdentifier("\(identifierPrefix)-donut")
        // 滑过扇区或点图例每换一项震一下，取消选中不震
        .appHaptic(.selection, trigger: selectedID) { _, id in id != nil }
        .overlay {
            GeometryReader { geometry in
                totalLabel
                    .frame(width: min(geometry.size.width, geometry.size.height) * 0.64)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .allowsHitTesting(false)
        }
    }

    /// 圆心：默认展示总额，选中一项时展示这一项的名称和金额。
    private var totalLabel: some View {
        let selected = breakdown.segments.first { $0.id == selectedID }
        return ShareDonutTotalLabel(
            title: selected?.title ?? totalTitle,
            amount: selected?.amount ?? breakdown.totalAmount,
            identifier: "\(identifierPrefix)-total"
        )
    }

    /// 图例同时提供图标、名称、百分比和完整金额播报，不依赖颜色识别。
    private var legend: some View {
        VStack(spacing: 0) {
            ForEach(breakdown.segments) { segment in
                Button {
                    selectedAngle = nil
                    selectedID = selectedID == segment.id ? nil : segment.id
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: segment.symbolName)
                            .font(.caption)
                            .foregroundStyle(color(segment))
                            .frame(width: legendSymbolWidth)
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(segment.title)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                percentageLabel(for: segment)
                            }
                            Spacer(minLength: 0)
                        } else {
                            Text(segment.title)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            percentageLabel(for: segment)
                        }
                    }
                    .foregroundStyle(.primary)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(segment.title)
                .accessibilityValue(Text(detail(for: segment)))
                .accessibilityAddTraits(selectedID == segment.id ? .isSelected : [])
                .accessibilityIdentifier("\(identifierPrefix)-legend-\(segment.id)")
            }
        }
    }

    /// 占比在常规字号右对齐，大字号时移至名称下方以保留完整名称。
    private func percentageLabel(for segment: CategoryRankingItem) -> some View {
        Text(breakdown.share(of: segment).formatted(
            .percent.precision(.fractionLength(1)).locale(locale)
        ))
        .font(.system(.caption, design: .serif).monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    /// 金额和百分比共用同一分母，供图形和可操作图例完整播报。
    private func detail(for segment: CategoryRankingItem) -> String {
        let amount = segment.amount.formattedCurrency(locale: locale)
        let share = breakdown.share(of: segment).formatted(.percent.precision(.fractionLength(1)).locale(locale))
        return "\(amount), \(share)"
    }
}

/// 环形图圆心的标题和金额；没有数据的空状态也用它写一个零总额。
struct ShareDonutTotalLabel: View {
    @Environment(\.locale) private var locale

    /// 金额上方的标题。
    let title: String

    /// 要写的金额。
    let amount: Decimal

    /// 自动化标识。
    let identifier: String

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(amount.formattedCurrency(locale: locale))
                .font(.system(.title3, design: .serif, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .contentTransition(.numericText())
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
