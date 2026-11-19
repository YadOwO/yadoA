import SwiftUI

/// 签到页里一个月的签到日历：月份标题和前后切换、星期行、按日排开的格子，最后一行是本月小结。
///
/// 签过的日子垫一块账本绿的手绘色块，今天加一圈墨线，得到礼包的那天右上角带一个礼盒小图标；还没到的日子用浅灰。
/// 数据由签到页按月查询后传入，这里只负责画。
struct CheckInCalendarView: View {
    @Environment(\.locale) private var locale

    /// 显示的月份。
    let month: CheckInCalendarMonth

    /// 这个月的签到数据；还没取到时为 nil。
    let data: AICheckInMonth?

    /// 服务端的今天，`YYYY-MM-DD`；用来标出今天、把以后的日子画浅。
    let today: String?

    /// 是否正在加载这个月。
    let isLoading: Bool

    /// 这个月是否加载失败。
    let didFail: Bool

    /// 能否翻到上个月：最早到第一次签到的那个月。
    let canGoBack: Bool

    /// 能否翻到下个月：最晚到当前月份。
    let canGoForward: Bool

    /// 翻到上个月。
    let onPrevious: () -> Void

    /// 翻到下个月。
    let onNext: () -> Void

    /// 加载失败后重试。
    let onRetry: () -> Void

    /// 每周从星期几开始，跟随系统的地区设置。
    private var firstWeekday: Int {
        Calendar.current.firstWeekday
    }

    /// 七列等宽的格子。
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        VStack(spacing: 14) {
            header

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }

                ForEach(0..<month.leadingBlankCount(firstWeekday: firstWeekday), id: \.self) { _ in
                    Color.clear
                        .frame(height: 42)
                        .accessibilityHidden(true)
                }

                ForEach(1...month.dayCount, id: \.self) { day in
                    dayCell(day)
                }
            }
            .id(month)
            .transition(.opacity)

            footer
        }
        .padding(16)
        .animation(.snappy(duration: 0.25), value: month)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("check-in-calendar")
    }

    // MARK: - 头部与小结

    /// 月份标题和左右切换按钮。
    private var header: some View {
        HStack {
            monthButton(symbol: "chevron.left", labelKey: "checkIn.calendar.previous", isEnabled: canGoBack, action: onPrevious)
                .accessibilityIdentifier("check-in-calendar-previous")

            Spacer()

            Text(month.title(locale: locale))
                .font(.system(.headline, design: .serif))
                .contentTransition(.opacity)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("check-in-calendar-title")

            Spacer()

            monthButton(symbol: "chevron.right", labelKey: "checkIn.calendar.next", isEnabled: canGoForward, action: onNext)
                .accessibilityIdentifier("check-in-calendar-next")
        }
        .appHaptic(.selection, trigger: month)
    }

    /// 前后翻月的按钮；到头时置灰。
    private func monthButton(symbol: String, labelKey: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!isEnabled)
        .accessibilityLabel(text(labelKey))
    }

    /// 最后一行：本月签了几天、共多少点；加载中、失败或没有签到时换成对应说明。
    @ViewBuilder
    private var footer: some View {
        if isLoading && data == nil {
            ProgressView()
                .frame(height: 20)
        } else if didFail && data == nil {
            Button(action: onRetry) {
                Text(text("checkIn.calendar.failed"))
                    .font(.footnote)
                    .foregroundStyle(Color(.ledgerRed))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("check-in-calendar-retry")
        } else if let data, !data.days.isEmpty {
            Text(
                String(
                    format: text("checkIn.calendar.summary"),
                    locale: locale,
                    data.days.count.formatted(.number.locale(locale)),
                    data.days.reduce(0) { $0 + $1.points }.formatted(.number.locale(locale))
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("check-in-calendar-summary")
        } else {
            Text(text("checkIn.calendar.empty"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 日期格

    /// 按周起始日排好的星期简写。
    private var weekdaySymbols: [String] {
        CheckInCalendarMonth.weekdaySymbols(firstWeekday: firstWeekday, locale: locale)
    }

    /// 某一天的格子。
    private func dayCell(_ day: Int) -> some View {
        let dateText = month.dateText(day: day)
        let record = data?.days.first { $0.date == dateText }
        let isToday = dateText == today
        let isFuture = today.map { dateText > $0 } ?? false
        let seed = dateText.handDrawnSeed

        return ZStack {
            if record != nil {
                HandDrawnBlob(seed: seed)
                    .fill(Color(.ledgerGreen).opacity(0.26))
                    .padding(3)
            }
            if isToday {
                HandDrawnBlob(seed: seed &+ 1)
                    .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .padding(3)
            }
            Text(day.formatted(.number.locale(locale)))
                .font(.system(.subheadline, design: .serif, weight: record != nil ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isFuture ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            if let tier = record?.giftTiers.first {
                Image(systemName: "gift.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tier.tint)
                    .offset(x: -2, y: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(day: day, record: record, isToday: isToday))
    }

    /// 某一天的朗读文本，例如“2026年11月5日，已签到，+12 点，连签第 3 天，获得周礼包”。
    private func accessibilityLabel(day: Int, record: AICheckInDay?, isToday: Bool) -> String {
        var parts = [month.spokenDate(day: day, locale: locale)]
        if isToday {
            parts.append(text("checkIn.calendar.today"))
        }
        if let record {
            parts.append(
                String(
                    format: text("checkIn.calendar.day.checked"),
                    locale: locale,
                    record.points.formatted(.number.locale(locale)),
                    record.streak.formatted(.number.locale(locale))
                )
            )
            parts += record.giftTiers.map { text($0.titleKey) }
        } else {
            parts.append(text("checkIn.calendar.day.unchecked"))
        }
        return parts.joined(separator: text("checkIn.calendar.separator"))
    }

    /// 按应用当前语言解析文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
