import Charts
import SwiftData
import SwiftUI

/// 分类统计二级页面；继承图表页筛选，并独立切换收支和周期。
struct CategoryBreakdownView: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Query private var transactions: [AccountTransaction]

    /// 当前收支类型、周期与业务日锚点。
    @State private var entryType: BookkeepingEntryType
    @State private var period: ChartPeriod
    @State private var anchorDay: Int
    /// 月份选择器的展示状态。
    @State private var isMonthPickerPresented = false

    /// 以父页面当前实际展示的筛选条件初始化，避免进入后跳到其他日期。
    init(entryType: BookkeepingEntryType, period: ChartPeriod, anchorDay: Int) {
        _entryType = State(initialValue: entryType)
        _period = State(initialValue: period)
        _anchorDay = State(initialValue: anchorDay)
        _transactions = Query(ChartOverviewPresentation.descriptor())
    }

    var body: some View {
        let chart = ChartOverviewPresentation(
            period: period,
            entryType: entryType,
            anchorDate: TransactionDay.date(from: anchorDay, calendar: calendar, locale: locale),
            transactions: transactions,
            calendar: calendar,
            locale: locale
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ChartEntryTypePicker(selection: $entryType)
                ChartPeriodPicker(selection: $period)
                ChartTimeSelector(
                    chart: chart,
                    onSelectPrevious: { shiftPeriod(by: -1, chart: chart) },
                    onSelectNext: { shiftPeriod(by: 1, chart: chart) },
                    onSelectMonth: { isMonthPickerPresented = true }
                )

                CategoryBreakdownCard(chart: chart)

                CategoryRankingView(
                    title: AccountLocalization.string(
                        entryType == .expense
                            ? "category.ranking.expense.title"
                            : "category.ranking.income.title",
                        locale: locale
                    ),
                    items: chart.categoryRanking
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .paperPage()
        .navigationTitle(AccountLocalization.string("chart.category.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
        .sheet(isPresented: $isMonthPickerPresented) {
            NavigationStack {
                HomeMonthPickerView(
                    initialMonth: HomeMonth.from(date: chart.anchorDate, calendar: calendar, locale: locale)
                        ?? HomeMonth(year: 1970, month: 1)!,
                    onCancel: { isMonthPickerPresented = false },
                    onConfirm: { month in
                        if let date = month.firstDate(calendar: calendar) {
                            anchorDay = TransactionDay.encode(date, calendar: calendar)
                        }
                        isMonthPickerPresented = false
                    }
                )
            }
        }
    }

    /// 按当前周期移动业务日，沿用图表页的日历和时区规则。
    private func shiftPeriod(by value: Int, chart: ChartOverviewPresentation) {
        if let date = ChartOverviewPresentation.shiftedAnchorDate(
            chart.anchorDate, period: period, by: value, calendar: calendar
        ) {
            anchorDay = TransactionDay.encode(date, calendar: calendar)
        }
    }
}

/// 原生环形图和可点选的图例；完整金额同时由下方排行榜提供。
private struct CategoryBreakdownCard: View {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    /// 图例图标预留宽度随字号缩放，避免辅助功能字号下与分类名称相互覆盖。
    @ScaledMetric(relativeTo: .caption) private var legendSymbolWidth = 20

    /// 与排行榜使用相同筛选条件的统计结果。
    let chart: ChartOverviewPresentation
    /// 点选扇区或图例后展示的分类，空值表示全部。
    @State private var selectedID: String?
    /// Swift Charts 返回的累计占比角度选择值。
    @State private var selectedAngle: Double?

    var body: some View {
        let breakdown = CategoryBreakdownPresentation(items: chart.categoryRanking, locale: locale)
        VStack(alignment: .leading, spacing: 18) {
            Text(AccountLocalization.string("chart.category.share", locale: locale))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if breakdown.segments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.pie")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    totalLabel(breakdown: breakdown)
                    Text(AccountLocalization.string("category.ranking.empty", locale: locale))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("category-breakdown-empty")
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if dynamicTypeSize.isAccessibilitySize {
                totalLabel(breakdown: breakdown)
                legend(breakdown: breakdown)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        donut(breakdown: breakdown)
                            .frame(width: 176, height: 220)
                        legend(breakdown: breakdown)
                            .frame(minWidth: 132)
                    }
                    VStack(spacing: 20) {
                        donut(breakdown: breakdown)
                            .frame(height: 240)
                        legend(breakdown: breakdown)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onChange(of: chart) { _, _ in
            selectedAngle = nil
            selectedID = nil
        }
    }

    /// 扇区之间留空隙；图标补充颜色编码，点击后中心显示该分类金额。
    private func donut(breakdown: CategoryBreakdownPresentation) -> some View {
        Chart(breakdown.segments) { segment in
            SectorMark(
                angle: .value(segment.title, breakdown.share(of: segment)),
                innerRadius: .ratio(0.7),
                outerRadius: .ratio(selectedID == segment.id ? 1 : 0.96),
                angularInset: 2
            )
            .cornerRadius(3)
            .foregroundStyle(color(for: segment))
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
            .accessibilityValue(Text(detail(for: segment, breakdown: breakdown)))
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
        .accessibilityIdentifier("category-breakdown-donut")
        .overlay {
            GeometryReader { geometry in
                totalLabel(breakdown: breakdown)
                    .frame(width: min(geometry.size.width, geometry.size.height) * 0.64)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .allowsHitTesting(false)
        }
    }

    /// 默认展示总额，选中分类时展示分类金额；再次点击图例可恢复总额。
    private func totalLabel(breakdown: CategoryBreakdownPresentation) -> some View {
        let selected = breakdown.segments.first { $0.id == selectedID }
        let title = selected?.title
            ?? AccountLocalization.string(chart.totalTitleLocalizationKey, locale: locale)
        let amount = (selected?.amount ?? breakdown.totalAmount)
            .formatted(.currency(code: "CNY").locale(locale))
        return VStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(amount)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .contentTransition(.numericText())
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("category-breakdown-total")
    }

    /// 图例同时提供图标、名称、百分比和完整金额播报，不依赖颜色识别分类。
    private func legend(breakdown: CategoryBreakdownPresentation) -> some View {
        VStack(spacing: 0) {
            ForEach(breakdown.segments) { segment in
                Button {
                    selectedAngle = nil
                    selectedID = selectedID == segment.id ? nil : segment.id
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: segment.symbolName)
                            .font(.caption)
                            .foregroundStyle(color(for: segment))
                            .frame(width: legendSymbolWidth)
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(segment.title)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                percentageLabel(for: segment, breakdown: breakdown)
                            }
                            Spacer(minLength: 0)
                        } else {
                            Text(segment.title)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            percentageLabel(for: segment, breakdown: breakdown)
                        }
                    }
                    .foregroundStyle(.primary)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(segment.title)
                .accessibilityValue(Text(detail(for: segment, breakdown: breakdown)))
                .accessibilityAddTraits(selectedID == segment.id ? .isSelected : [])
                .accessibilityIdentifier("category-breakdown-legend-\(segment.id)")
            }
        }
    }

    /// 占比在常规字号右对齐，大字号时移至名称下方以保留完整分类名称。
    private func percentageLabel(
        for segment: CategoryRankingItem,
        breakdown: CategoryBreakdownPresentation
    ) -> some View {
        Text(breakdown.share(of: segment).formatted(
            .percent.precision(.fractionLength(1)).locale(locale)
        ))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    /// 分类金额和百分比共用同一分母，供图形和可操作图例完整播报。
    private func detail(for segment: CategoryRankingItem, breakdown: CategoryBreakdownPresentation) -> String {
        let amount = segment.amount.formatted(.currency(code: "CNY").locale(locale))
        let share = breakdown.share(of: segment).formatted(.percent.precision(.fractionLength(1)).locale(locale))
        return "\(amount), \(share)"
    }

    /// 固定分类映射的三色组合与分类图标共同编码，筛选或排行变化不重新分配颜色。
    /// 浅深色分别使用经过验证的色阶；合并项用语义灰色，与账本“其他”分类区分。
    private func color(for segment: CategoryRankingItem) -> Color {
        if differentiateWithoutColor || segment.id == CategoryBreakdownPresentation.remainingID {
            return Color(uiColor: .secondaryLabel)
        }
        let light: UInt32
        let dark: UInt32
        switch segment.id {
        case "expense.shopping", "expense.clothing", "expense.household", "expense.socialGifts",
             "income.bonus", "income.reimbursement", "income.gifts":
            (light, dark) = (0xEB6834, 0xD95926)
        case "expense.entertainment", "expense.transportation", "expense.travel", "expense.pets",
             "expense.other", "income.investment", "income.refund", "income.other":
            (light, dark) = (0x1BAF7A, 0x199E70)
        default:
            (light, dark) = (0x2A78D6, 0x3987E5)
        }
        let hex = colorScheme == .dark ? dark : light
        return Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

#if DEBUG
#Preview("分类统计 · 浅色") {
    NavigationStack {
        CategoryBreakdownView(
            entryType: .expense, period: .month,
            anchorDay: TransactionDay.encode(.now, calendar: .current)
        )
    }
    .modelContainer(try! HomeDesignPreviewData.makeContainer())
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#Preview("Category breakdown · Dark") {
    NavigationStack {
        CategoryBreakdownView(
            entryType: .expense, period: .month,
            anchorDay: TransactionDay.encode(.now, calendar: .current)
        )
    }
    .modelContainer(try! HomeDesignPreviewData.makeContainer())
    .environment(\.locale, Locale(identifier: "en"))
    .preferredColorScheme(.dark)
}
#endif
