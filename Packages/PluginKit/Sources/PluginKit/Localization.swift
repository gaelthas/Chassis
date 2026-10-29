import Foundation
import PluginAPI
import SwiftUI

extension LocalizedStringKey {
    /// 取出无插值 key 的字面量。
    ///
    /// 仅用于基座内部的纯文本场景（日志、快捷键冲突提示）——UI 一律用
    /// `Text(title, bundle: manifest.resourceBundle)`，不走这里。
    var plainKey: String? {
        for child in Mirror(reflecting: self).children where child.label == "key" {
            return child.value as? String
        }
        return nil
    }
}

extension PluginManifest {
    /// 本地化后的纯文本标题。
    var localizedTitle: String? {
        guard let key = title.plainKey else { return nil }
        return resourceBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    var localizedSummary: String? {
        guard let key = summary.plainKey else { return nil }
        return resourceBundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
