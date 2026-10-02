import SwiftData
import SwiftUI

/// 账单页：月模式查看某年每月收支，年模式查看全部年份收支。
struct BillView: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Query private var transactions: [AccountTransaction]

    /// 模式切换保留用户上次选中的月账单年份。
    @State private var period: BillPeriod = .monthly
    /// 未选择时默认当前年，切换年账单不清空此值。
    @State private var selectedYear: Int?

    var body: some View {
        let presentation = BillOverviewPresentation(
            transactions: transactions, calendar: calendar, locale: locale
        )
        let year = selectedYear ?? presentation.currentMonth.year
        let totals = period == .monthly ? presentation.totals(for: year) : presentation.total

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker(AccountLocalization.string("bill.period.label", locale: locale), selection: $period) {
                    ForEach(BillPeriod.allCases) { period in
                        Text(period.title(locale: locale)).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("bill-period-picker")

                if period == .monthly {
                    Menu {
                        Picker(
                            AccountLocalization.string("bill.year.select", locale: locale),
                            selection: Binding(get: { year }, set: { selectedYear = $0 })
                        ) {
                            ForEach(Set(presentation.availableYears + [year]).sorted(by: >), id: \.self) { year in
                                Text(presentation.yearTitle(year)).tag(year)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(presentation.yearTitle(year)).font(.headline)
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel(AccountLocalization.string("bill.year.select", locale: locale))
                    .accessibilityValue(presentation.yearTitle(year))
                    .accessibilityIdentifier("bill-year-selector")
                }

                BillSummaryCard(totals: totals, period: period)

                if totals.transactionCount == 0 {
                    ContentUnavailableView(
                        AccountLocalization.string("bill.empty.title", locale: locale),
                        systemImage: "doc.text",
                        description: Text(AccountLocalization.string("bill.empty.message", locale: locale))
                    )
                    .accessibilityIdentifier("bill-empty")
                } else {
                    BillTable(
                        rows: period == .monthly ? presentation.monthlyRows(for: year) : presentation.yearlyRows,
                        period: period
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(AccountLocalization.string("bill.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 延续首页圆角卡片和圆体数字，以结余为主、收入支出为辅。
private struct BillSummaryCard: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 当前模式对应的汇总与文案范围。
    let totals: BillTotals
    let period: BillPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(AccountLocalization.string(
                    period == .monthly ? "bill.summary.yearBalance" : "bill.summary.totalBalance",
                    locale: locale
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(totals.balance.formatted(.currency(code: "CNY").locale(locale)))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityIdentifier("bill-summary-balance")
            }
            Divider()
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            layout {
                amount(totals.income, titleKey: "bill.income", symbol: "arrow.down.left", isIncome: true)
                amount(totals.expense, titleKey: "bill.expense", symbol: "arrow.up.right", isIncome: false)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }

    /// 收入沿用主题色，支出使用主文字色；图标与标题同时传达含义。
    private func amount(_ value: Decimal, titleKey: String, symbol: String, isIncome: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(AccountLocalization.string(titleKey, locale: locale), systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value.formatted(.currency(code: "CNY").locale(locale)))
                .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                .foregroundStyle(isIncome ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityIdentifier(isIncome ? "bill-summary-income" : "bill-summary-expense")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 周期收支表；窄屏、大额数字或辅助功能字号下改为纵向明细，保留完整金额。
private struct BillTable: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 已按时间倒序排列的账单行。
    let rows: [BillRowPresentation]
    /// 决定第一列表头显示月份还是年份。
    let period: BillPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(AccountLocalization.string("bill.details", locale: locale))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(AccountLocalization.string("bill.currency", locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if dynamicTypeSize.isAccessibilitySize {
                stackedRows
            } else {
                ViewThatFits(in: .horizontal) {
                    table
                    stackedRows
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }

    /// 原生 Grid 统一列宽，数字使用固有宽度以触发窄屏降级。
    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                heading(period == .monthly ? "bill.month" : "bill.year")
                    .gridColumnAlignment(.leading)
                heading("bill.income")
                heading("bill.expense")
                heading("bill.balance")
            }
            .padding(.bottom, 12)

            ForEach(rows) { row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(row.title).font(.subheadline.weight(.medium)).fixedSize()
                    numericText(row.totals.income, isIncome: true)
                    numericText(row.totals.expense)
                    numericText(row.totals.balance)
                }
                .padding(.vertical, 16)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(rowLabel(row))
                .accessibilityIdentifier("bill-row-\(row.id)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 自适应明细把每个金额放到单独一行，避免挤压和截断。
    private var stackedRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(rows) { row in
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(row.title).font(.headline)
                    LabeledContent(AccountLocalization.string("bill.income", locale: locale)) {
                        numericText(row.totals.income, isIncome: true)
                    }
                    LabeledContent(AccountLocalization.string("bill.expense", locale: locale)) {
                        numericText(row.totals.expense)
                    }
                    LabeledContent(AccountLocalization.string("bill.balance", locale: locale)) {
                        numericText(row.totals.balance)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(rowLabel(row))
                .accessibilityIdentifier("bill-row-\(row.id)")
            }
        }
    }

    /// 表头使用与正文区分的次级文字。
    private func heading(_ key: String) -> some View {
        Text(AccountLocalization.string(key, locale: locale))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    /// 表格统一在标题注明 CNY，单元格保留完整的两位小数。
    private func numericText(_ amount: Decimal, isIncome: Bool = false) -> some View {
        Text(formatted(amount))
            .font(.system(.subheadline, design: .rounded).monospacedDigit())
            .foregroundStyle(isIncome ? Color.accentColor : Color.primary)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Decimal 直接格式化，避免经过 Double 丢失精度。
    private func formatted(_ amount: Decimal) -> String {
        amount.formatted(.number.precision(.fractionLength(2)).locale(locale))
    }

    /// VoiceOver 逐行读出周期、收入、支出和结余，避免丢失列含义。
    private func rowLabel(_ row: BillRowPresentation) -> String {
        [
            row.title,
            AccountLocalization.string("bill.income", locale: locale), formatted(row.totals.income),
            AccountLocalization.string("bill.expense", locale: locale), formatted(row.totals.expense),
            AccountLocalization.string("bill.balance", locale: locale), formatted(row.totals.balance)
        ].joined(separator: ", ")
    }
}

#if DEBUG
#Preview("Monthly bills") {
    NavigationStack { BillView() }
        .modelContainer(try! HomeDesignPreviewData.makeContainer())
        .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#Preview("Empty bills · Dark") {
    NavigationStack { BillView() }
        .modelContainer(try! HomeDesignPreviewData.makeContainer(isEmpty: true))
        .preferredColorScheme(.dark)
}
#endif
