import SwiftUI

extension View {
    /// 把页面底色换成账本的纸色，并让页面内的系统列表、表单透出这层纸色。
    ///
    /// 纸色与应用图标的底色一致：浅色外观是暖白的纸，深色外观是墨底。
    /// 卡片和列表行继续使用系统分组色，保证与原生控件的层级关系不变。
    func paperPage() -> some View {
        scrollContentBackground(.hidden)
            .background(Color(.paperBackground).ignoresSafeArea())
    }
}
