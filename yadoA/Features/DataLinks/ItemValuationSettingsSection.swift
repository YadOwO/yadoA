import SwiftUI

/// 物品估值的三个设置：显示在账户页、计入净资产、折扣；数据联动页和估值详情页共用。
///
/// 设置读写 `DataLinkStore.settings`，按 Logto 用户 ID 存在本机，写入时折扣会夹进 10%～100% 并对齐到 5%。
/// 「显示在账户页」和「计入净资产」互相独立：关掉显示、开着计入时，估值仍算进汇总卡片和资产分析。
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

                Toggle(isOn: binding(\.countsInNetWorth)) {
                    Label(text("itemValuation.setting.countsInNetWorth"), systemImage: "chart.line.uptrend.xyaxis")
                        .labelStyle(ProfileSettingsLabelStyle())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .accessibilityIdentifier("item-valuation-counts-in-net-worth")

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
