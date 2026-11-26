import SwiftUI

/// 物品估值的三个设置：显示在账户页、计入净资产、折扣；数据联动页和估值详情页共用。
///
/// 设置读写 `DataLinkStore.settings`，按 Logto 用户 ID 存在本机，写入时折扣会夹进 10%～100% 并对齐到 5%。
/// 关掉「显示在账户页」时估值也不计入净资产：「计入净资产」置灰并显示为关，下面一行说明原因；
/// 用户存的「计入净资产」不改，重新打开显示后恢复。
struct ItemValuationSettingsSection: View {
    @Environment(\.locale) private var locale

    /// 联动状态；设置都存在它里面。
    let store: DataLinkStore

    var body: some View {
        let settings = store.settings

        VStack(alignment: .leading, spacing: 10) {
            ProfileSettingsSection(nil, seed: "itemValuation.settings") {
                Toggle(isOn: binding(\.showsOnAccounts)) {
                    Label(text("itemValuation.setting.showsOnAccounts"), systemImage: "eye")
                        .labelStyle(ProfileSettingsLabelStyle())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .accessibilityIdentifier("item-valuation-shows-on-accounts")

                ProfileSettingsRowDivider()

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: countsInNetWorthBinding) {
                        Label(text("itemValuation.setting.countsInNetWorth"), systemImage: "chart.line.uptrend.xyaxis")
                            .labelStyle(ProfileSettingsLabelStyle())
                    }
                    .disabled(!settings.showsOnAccounts)
                    .accessibilityHint(settings.showsOnAccounts ? "" : text("itemValuation.setting.countsInNetWorth.needsShow"))
                    .accessibilityIdentifier("item-valuation-counts-in-net-worth")

                    if !settings.showsOnAccounts {
                        Text(text("itemValuation.setting.countsInNetWorth.needsShow"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                ProfileSettingsRowDivider()

                Stepper(
                    value: Binding(
                        get: { settings.discountPercent },
                        set: { newValue in
                            var updated = store.settings
                            updated.discountPercent = newValue
                            store.settings = updated
                        }
                    ),
                    in: ItemValuationSettings.discountRange,
                    step: ItemValuationSettings.discountStep
                ) {
                    HStack(spacing: 8) {
                        Label(text("itemValuation.setting.discount"), systemImage: "percent")
                            .labelStyle(ProfileSettingsLabelStyle())
                        Spacer(minLength: 4)
                        Text(discountText(settings.discountPercent))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .accessibilityValue(discountText(settings.discountPercent))
                .accessibilityIdentifier("item-valuation-discount")
            }

            Text(text("itemValuation.settings.footnote"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
        }
    }

    /// 「计入净资产」开关的绑定：关掉「显示在账户页」时显示为关（实际也不计入），并且不写入，用户原来的选择保留到重新打开显示。
    private var countsInNetWorthBinding: Binding<Bool> {
        Binding(
            get: { store.settings.countsTowardNetWorth },
            set: { newValue in
                var updated = store.settings
                guard updated.showsOnAccounts else { return }
                updated.countsInNetWorth = newValue
                store.settings = updated
            }
        )
    }

    /// 某个开关的双向绑定：读最新设置，写时整份写回，让存储统一夹取折扣。
    ///
    /// - Parameter keyPath: 设置里的开关字段。
    private func binding(_ keyPath: WritableKeyPath<ItemValuationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = store.settings
                updated[keyPath: keyPath] = newValue
                store.settings = updated
            }
        )
    }

    /// 折扣在界面上的写法，例如「7 折」「70%」。
    private func discountText(_ percent: Int) -> String {
        ItemValuation.discountText(percent: percent, locale: locale)
    }

    /// 按应用当前语言解析 String Catalog 文案。
    private func text(_ key: String) -> String {
        AccountLocalization.string(key, locale: locale)
    }
}
