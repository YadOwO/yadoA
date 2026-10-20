import Foundation
import Testing
import UIKit
@testable import yadoA

@Suite("分类图标库")
@MainActor
struct CategorySymbolLibraryTests {
    @Test("每个图标都能在当前系统加载；在 iOS 18 模拟器上运行即验证最低版本可用")
    func everySymbolLoads() {
        let missing = CategorySymbolLibrary.allSymbols
            .map(\.name)
            .filter { UIImage(systemName: $0) == nil }
        #expect(missing.isEmpty, "无法加载的图标：\(missing)")
    }

    @Test("图标不重复，且覆盖全部预置分类的默认图标")
    func symbolsAreUniqueAndCoverPresets() {
        let names = CategorySymbolLibrary.allSymbols.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.count >= 200)
        let presetSymbols = Set(BookkeepingCategoryKey.allPresets.map(\.symbolName))
        #expect(presetSymbols.isSubset(of: Set(names)))
    }

    @Test("每个分组都有图标和中英文名称")
    func everyGroupIsPopulated() {
        #expect(CategorySymbolLibrary.groups.map(\.group) == CategorySymbolGroup.allCases)
        for section in CategorySymbolLibrary.groups {
            #expect(!section.symbols.isEmpty)
            let english = section.group.localizedTitle(locale: Locale(identifier: "en"))
            let chinese = section.group.localizedTitle(locale: Locale(identifier: "zh-Hans"))
            #expect(english != section.group.localizationKey)
            #expect(chinese != section.group.localizationKey)
        }
    }

    @Test("中英文关键词都能搜到图标，不区分界面语言", arguments: [
        ("咖啡", "cup.and.saucer"),
        ("coffee", "cup.and.saucer"),
        ("COFFEE", "cup.and.saucer"),
        ("猫", "cat"),
        ("地铁", "tram.fill.tunnel"),
        ("gym", "dumbbell"),
        ("airplane", "airplane")
    ])
    func searchMatchesKeywords(query: String, expected: String) {
        let names = CategorySymbolLibrary.search(query, locale: Locale(identifier: "zh-Hans"))
            .flatMap(\.symbols)
            .map(\.name)
        #expect(names.contains(expected))
    }

    @Test("搜索结果保留分组，空关键词返回全部，无匹配返回空")
    func searchKeepsGroups() {
        #expect(CategorySymbolLibrary.search("  ").count == CategorySymbolLibrary.groups.count)
        #expect(CategorySymbolLibrary.search("zzz").isEmpty)
        let petSections = CategorySymbolLibrary.search("猫")
        #expect(petSections.map(\.group).contains(.pets))
        #expect(petSections.allSatisfy { !$0.symbols.isEmpty })
    }
}
