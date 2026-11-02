import SwiftData
import SwiftUI

/// 账单页：月模式查看某年每月收支，年模式查看全部年份收支。
struct BillView: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.colorScheme) private var colorScheme
    @Query private var transactions: [AccountTransaction]

    /// 账单页独立保存结余配色，默认正红负绿。
    @AppStorage("bill.balance.positiveIsRed") private var positiveBalanceIsRed = true

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
            VStack(alignment: .leading, spacing: 22) {
                LedgerSwitch(
                    label: AccountLocalization.string("bill.period.label", locale: locale),
                    selection: $period,
                    options: BillPeriod.allCases.map {
                        .init(
                            value: $0,
                            title: $0.title(locale: locale),
                            identifier: "bill-period-picker-\($0.rawValue)"
                        )
                    }
                )

                // 年份选择放进汇总框的标题行；该行高度固定，切换月/年账单时下方内容不会上下跳动。
                BillSummaryCard(totals: totals, period: period, positiveBalanceIsRed: positiveBalanceIsRed) {
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
                            HStack(spacing: 6) {
                                Text(presentation.yearTitle(year)).font(.system(.headline, design: .serif))
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
                }

                if totals.transactionCount == 0 {
                    ContentUnavailableView {
                        // 与首页空状态一致，图标换成手绘小票。
                        Label {
                            Text(AccountLocalization.string("bill.empty.title", locale: locale))
                        } icon: {
                            HandDrawnSlipIllustration()
                        }
                    } description: {
                        Text(AccountLocalization.string("bill.empty.message", locale: locale))
                    }
                    .accessibilityIdentifier("bill-empty")
                } else {
                    BillTable(
                        rows: period == .monthly ? presentation.monthlyRows(for: year) : presentation.yearlyRows,
                        period: period,
                        positiveBalanceIsRed: positiveBalanceIsRed
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .paperPage()
        .navigationTitle(AccountLocalization.string("bill.title", locale: locale))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(
                        AccountLocalization.string("bill.balance.color", locale: locale),
                        selection: $positiveBalanceIsRed
                    ) {
                        // 系统菜单不支持给部分文字上色，改用带颜色的正负号示意两种配色。
                        Label {
                            Text(AccountLocalization.string("bill.balance.positiveRed", locale: locale))
                        } icon: {
                            billBalanceSwatch(positiveIsRed: true, colorScheme: colorScheme)
                        }
                        .tag(true)
                        Label {
                            Text(AccountLocalization.string("bill.balance.positiveGreen", locale: locale))
                        } icon: {
                            billBalanceSwatch(positiveIsRed: false, colorScheme: colorScheme)
                        }
                        .tag(false)
                    }
                } label: {
                    Label(
                        AccountLocalization.string("bill.balance.color", locale: locale),
                        systemImage: "paintpalette"
                    )
                }
                .accessibilityIdentifier("bill-balance-color")
            }
        }
    }
}

/// 延续首页的墨线框和衬线数字，以结余为主、收入支出为辅。
private struct BillSummaryCard<Accessory: View>: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 当前模式对应的汇总与文案范围。
    let totals: BillTotals
    let period: BillPeriod
    /// 汇总和明细共用页面选择的结余配色。
    let positiveBalanceIsRed: Bool
    /// 标题行右侧的附加控件，月账单下是年份选择；为空时标题行高度不变。
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(AccountLocalization.string(
                        period == .monthly ? "bill.summary.yearBalance" : "bill.summary.totalBalance",
                        locale: locale
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    accessory()
                }
                // 无论右侧是否有年份选择，标题行都保持同一高度。
                .frame(minHeight: 44)
                Text(totals.balance.formatted(.currency(code: "CNY").locale(locale)))
                    .font(.system(.largeTitle, design: .serif, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(billBalanceColor(totals.balance, positiveIsRed: positiveBalanceIsRed))
                    .accessibilityIdentifier("bill-summary-balance")
            }
            HandDrawnRule(seed: 11)
                .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(height: 3)
                .accessibilityHidden(true)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            layout {
                amount(totals.income, titleKey: "bill.income", symbol: "arrow.down.left", isIncome: true)
                amount(totals.expense, titleKey: "bill.expense", symbol: "arrow.up.right", isIncome: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 不垫实色卡片，直接写在纸上，用一笔画成的墨线框圈出来。
        .background {
            HandDrawnBox(cornerRadius: 24, seed: 3)
                .stroke(
                    Color.primary.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
        }
    }

    /// 收入和支出统一使用主文字色，图标与标题传达收支含义。
    private func amount(_ value: Decimal, titleKey: String, symbol: String, isIncome: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(AccountLocalization.string(titleKey, locale: locale), systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value.formatted(.currency(code: "CNY").locale(locale)))
                .font(.system(.title3, design: .serif, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityIdentifier(isIncome ? "bill-summary-income" : "bill-summary-expense")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 周期收支明细：每个周期一行，右边是结余，收入和支出作为小字写在下面一行。
///
/// 不再把三列带小数的数字并排成表格——那样满屏都是同样大小的数字；现在一眼先看到各期结余，
/// 需要时再读下面的收支。
private struct BillTable: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 已按时间倒序排列的账单行。
    let rows: [BillRowPresentation]
    /// 当前是月账单还是年账单。
    let period: BillPeriod
    /// 汇总和明细共用页面选择的结余配色。
    let positiveBalanceIsRed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(AccountLocalization.string("bill.details", locale: locale))
                    .font(.system(.headline, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // 右侧一列都是结余，在表头注明一次，金额统一以人民币计。
                Text(verbatim: "\(text("bill.balance")) · \(text("bill.currency"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rule(for: row, isHeading: index == 0)
                rowView(row)
                    .padding(.vertical, 14)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(rowLabel(row))
                    .accessibilityIdentifier("bill-row-\(row.id)")
            }
        }
        // 明细像账本内页一样直接写在纸上，不再垫卡片。
        .padding(.horizontal, 2)
        .padding(.top, 6)
    }

    /// 一个周期：第一行是周期和结余，第二行是较小的收入、支出。
    private func rowView(_ row: BillRowPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.title)
                    .font(.system(.body, design: .serif, weight: .medium))
                Spacer(minLength: 8)
                Text(formatted(row.totals.balance))
                    .font(.system(.body, design: .serif, weight: .medium).monospacedDigit())
                    .foregroundStyle(billBalanceColor(row.totals.balance, positiveIsRed: positiveBalanceIsRed))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            // 两个金额一行放不下（大额或大字号）时改为上下两行，不截断数字。
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 18))
            ViewThatFits(in: .horizontal) {
                layout {
                    detail("bill.income", row.totals.income)
                    detail("bill.expense", row.totals.expense)
                }
                VStack(alignment: .leading, spacing: 4) {
                    detail("bill.income", row.totals.income)
                    detail("bill.expense", row.totals.expense)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 第二行里的"收入 1,234.00"这样一小段。
    private func detail(_ titleKey: String, _ amount: Decimal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(text(titleKey))
                .font(.caption)
            Text(formatted(amount))
                .font(.system(.footnote, design: .serif).monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    /// 按当前应用语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }

    /// 行上方的手画横线：表头下面是一条较重的墨线，其余是较淡的账本横线。
    private func rule(for row: BillRowPresentation, isHeading: Bool) -> some View {
        HandDrawnRule(seed: UInt64(truncatingIfNeeded: row.id))
            .stroke(
                Color.primary.opacity(isHeading ? 0.6 : 0.16),
                style: StrokeStyle(lineWidth: isHeading ? 1.3 : 1, lineCap: .round)
            )
            .frame(height: 3)
            .accessibilityHidden(true)
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

/// 正负结余按用户偏好映射为账本红、账本绿，零结余保持中性文字色。
private func billBalanceColor(_ amount: Decimal, positiveIsRed: Bool) -> Color {
    guard amount != 0 else { return .primary }
    return (amount > 0) == positiveIsRed ? Color(.ledgerRed) : Color(.ledgerGreen)
}

/// 配色菜单项里的示意图：带颜色的加号和减号，对应正、负结余各自的颜色。
///
/// 系统菜单只会原样显示"原色"位图，因此按当前外观把两种颜色画进一张图。
@MainActor
private func billBalanceSwatch(positiveIsRed: Bool, colorScheme: ColorScheme) -> Image {
    let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
    let red = UIColor(resource: .ledgerRed).resolvedColor(with: traits)
    let green = UIColor(resource: .ledgerGreen).resolvedColor(with: traits)
    let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)

    guard
        let plus = UIImage(systemName: "plus", withConfiguration: configuration)?
            .withTintColor(positiveIsRed ? red : green, renderingMode: .alwaysOriginal),
        let minus = UIImage(systemName: "minus", withConfiguration: configuration)?
            .withTintColor(positiveIsRed ? green : red, renderingMode: .alwaysOriginal)
    else {
        return Image(systemName: "plusminus")
    }

    let spacing: CGFloat = 4
    let size = CGSize(
        width: plus.size.width + spacing + minus.size.width,
        height: max(plus.size.height, minus.size.height)
    )
    let image = UIGraphicsImageRenderer(size: size).image { _ in
        plus.draw(at: CGPoint(x: 0, y: (size.height - plus.size.height) / 2))
        minus.draw(at: CGPoint(x: plus.size.width + spacing, y: (size.height - minus.size.height) / 2))
    }
    return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
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
