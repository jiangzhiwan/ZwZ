import Foundation
import SwiftUI

// MARK: - Language Manager

@MainActor
class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published private(set) var currentLanguage: String

    private init() {
        // 从 UserDefaults 读取，默认跟随系统
        let saved = UserDefaults.standard.string(forKey: "zwz_language")
        if let saved = saved {
            currentLanguage = saved
        } else {
            // 跟随系统语言
            let preferredLang = Locale.preferredLanguages.first ?? "en"
            currentLanguage = preferredLang.hasPrefix("zh") ? "zh" : "en"
        }
    }

    func setLanguage(_ lang: String) {
        guard currentLanguage != lang else { return }
        currentLanguage = lang
        UserDefaults.standard.set(lang, forKey: "zwz_language")
    }
}

// MARK: - Localized Strings

struct L {
    // 中文
    static let zh: [String: String] = [
        "app_name": "zwz",
        "new_tab": "新标签页",
        "open_archive_choice": "如何打开这个项目？",
        "open_in_new_tab": "在新标签页打开",
        "replace_current_tab": "替换当前标签页",
        "file_missing": "文件缺失",
        "relocate": "重新定位",
        "close_tab": "关闭标签页",
        "close_running_title": "此标签页的任务仍在运行",
        "cancel_and_close": "取消任务并关闭",
        "compress": "压缩",
        "extract": "解压",
        "smart_extract": "智能解压",
        "smart_extracting": "正在智能解压…",
        "preview": "预览",
        "drop_hint": "拖拽文件到此处",
        "supported_formats": "支持 ZIP、ZWZ、RAR、7Z、TAR.GZ、TGZ、GZ",
        "select_compress": "选择文件压缩",
        "select_extract": "选择压缩包解压",
        "compress_settings": "压缩设置",
        "source_file": "源文件",
        "compress_level": "压缩等级",
        "password_optional": "密码（可选）",
        "enter_password": "输入密码",
        "split_size_optional": "分卷大小（可选）",
        "cancel": "取消",
        "start_compress": "开始压缩",
        "extract_settings": "解压设置",
        "archive": "压缩包",
        "detected_format": "检测到的格式",
        "password_if_needed": "密码（如果需要）",
        "start_extract": "开始解压",
        "archive_contents": "压缩包内容",
        "search_archive_contents": "搜索压缩包内容",
        "no_search_results": "未找到匹配项目",
        "preview_loading": "正在准备预览…",
        "preview_unsupported": "暂不支持预览此文件类型",
        "preview_failed": "无法预览此文件",
        "preview_retry": "重试",
        "preview_text_truncated": "仅显示前 2 MB 内容",
        "preview_text_encoding": "编码：%@",
        "close_preview": "关闭预览",
        "zoom_in": "放大",
        "zoom_out": "缩小",
        "fit_to_window": "适应窗口",
        "actual_size": "原始尺寸",
        "close": "关闭",
        "total_items": "共 %d 个项目",
        "total_size": "总大小: %@",
        "recent_operations": "最近操作",
        "ready": "就绪",
        "compressing": "正在压缩…",
        "extracting": "正在解压…",
        "reading": "正在读取…",
        "done": "完成",
        "error": "错误",
        "ok": "确定",
        "none": "无压缩",
        "fastest": "最快",
        "normal": "标准",
        "max": "最大压缩",
        "unsupported_zwz_version": "不支持旧版 ZWZ 压缩包，请使用当前版本重新压缩。",
        "archive_password_required": "预览此加密压缩包需要密码。",
        "archive_password_or_tampered": "密码错误或压缩包数据已损坏。",
        "preview_password_title": "需要密码",
        "preview_with_password": "预览",
        "missing_archive_volume": "缺少压缩包分卷：第 %d 卷。",
        "recovery_partial": "恢复完成，部分文件已作为不完整文件输出。",
        "batch_rename": "批量重命名",
        "batch_rename_rule": "重命名规则",
        "batch_rename_find_replace": "查找和替换",
        "batch_rename_prefix_suffix": "添加前后缀",
        "batch_rename_numbering": "序号编号",
        "batch_rename_regex": "正则表达式替换",
        "batch_rename_case": "大小写转换",
        "batch_rename_find": "查找",
        "batch_rename_replace": "替换为",
        "batch_rename_prefix": "前缀",
        "batch_rename_suffix": "后缀",
        "batch_rename_start": "起始序号",
        "batch_rename_step": "步长",
        "batch_rename_digits": "位数",
        "batch_rename_template": "模板",
        "batch_rename_pattern": "正则表达式",
        "batch_rename_case_mode": "大小写模式",
        "batch_rename_case_upper": "全大写",
        "batch_rename_case_lower": "全小写",
        "batch_rename_case_title": "首字母大写",
        "batch_rename_case_camel": "驼峰命名",
        "batch_rename_case_snake": "下划线命名",
        "batch_rename_include_ext": "包含扩展名",
        "batch_rename_scope": "范围",
        "batch_rename_scope_selected": "手动多选",
        "batch_rename_scope_all": "当前目录全部",
        "batch_rename_select_all": "全选",
        "batch_rename_deselect_all": "取消全选",
        "batch_rename_preview": "预览",
        "batch_rename_original": "原名",
        "batch_rename_new": "新名",
        "batch_rename_conflict": "冲突",
        "batch_rename_no_change": "无变化",
        "batch_rename_apply": "应用重命名",
        "batch_rename_cancel": "取消",
        "batch_rename_count": "共 %d 项",
        "batch_rename_numbering_simple": "简单模式",
        "batch_rename_numbering_template": "模板模式",
    ]

    // English
    static let en: [String: String] = [
        "app_name": "zwz",
        "new_tab": "New Tab",
        "open_archive_choice": "How would you like to open this item?",
        "open_in_new_tab": "Open in New Tab",
        "replace_current_tab": "Replace Current Tab",
        "file_missing": "File Missing",
        "relocate": "Relocate",
        "close_tab": "Close Tab",
        "close_running_title": "A task is still running in this tab",
        "cancel_and_close": "Cancel Task and Close",
        "compress": "Compress",
        "extract": "Extract",
        "smart_extract": "Smart Extract",
        "smart_extracting": "Smart extracting…",
        "preview": "Preview",
        "drop_hint": "Drop files here",
        "supported_formats": "Supports ZIP, ZWZ, RAR, 7Z, TAR.GZ, TGZ, GZ",
        "select_compress": "Select File to Compress",
        "select_extract": "Select Archive to Extract",
        "compress_settings": "Compress Settings",
        "source_file": "Source File",
        "compress_level": "Compression Level",
        "password_optional": "Password (Optional)",
        "enter_password": "Enter password",
        "split_size_optional": "Split Size (Optional)",
        "cancel": "Cancel",
        "start_compress": "Start Compress",
        "extract_settings": "Extract Settings",
        "archive": "Archive",
        "detected_format": "Detected Format",
        "password_if_needed": "Password (if needed)",
        "start_extract": "Start Extract",
        "archive_contents": "Archive Contents",
        "search_archive_contents": "Search archive contents",
        "no_search_results": "No matching items",
        "preview_loading": "Preparing preview…",
        "preview_unsupported": "This file type cannot be previewed",
        "preview_failed": "Unable to preview this file",
        "preview_retry": "Retry",
        "preview_text_truncated": "Showing only the first 2 MB",
        "preview_text_encoding": "Encoding: %@",
        "close_preview": "Close Preview",
        "zoom_in": "Zoom In",
        "zoom_out": "Zoom Out",
        "fit_to_window": "Fit to Window",
        "actual_size": "Actual Size",
        "close": "Close",
        "total_items": "%d items",
        "total_size": "Total: %@",
        "recent_operations": "Recent Operations",
        "ready": "Ready",
        "compressing": "Compressing…",
        "extracting": "Extracting…",
        "reading": "Reading…",
        "done": "Done",
        "error": "Error",
        "ok": "OK",
        "none": "None",
        "fastest": "Fastest",
        "normal": "Normal",
        "max": "Max",
        "unsupported_zwz_version": "Unsupported ZWZ archive version. Please recompress this folder with the current app.",
        "archive_password_required": "Password required to preview this encrypted archive.",
        "archive_password_or_tampered": "The password is incorrect or the archive data was modified.",
        "preview_password_title": "Password Required",
        "preview_with_password": "Preview",
        "missing_archive_volume": "Archive volume %d is missing.",
        "recovery_partial": "Recovery completed with partial files.",
        "batch_rename": "Batch Rename",
        "batch_rename_rule": "Rename Rule",
        "batch_rename_find_replace": "Find & Replace",
        "batch_rename_prefix_suffix": "Add Prefix/Suffix",
        "batch_rename_numbering": "Numbering",
        "batch_rename_regex": "Regex Replace",
        "batch_rename_case": "Case Conversion",
        "batch_rename_find": "Find",
        "batch_rename_replace": "Replace With",
        "batch_rename_prefix": "Prefix",
        "batch_rename_suffix": "Suffix",
        "batch_rename_start": "Start Number",
        "batch_rename_step": "Step",
        "batch_rename_digits": "Digits",
        "batch_rename_template": "Template",
        "batch_rename_pattern": "Regex Pattern",
        "batch_rename_case_mode": "Case Mode",
        "batch_rename_case_upper": "UPPERCASE",
        "batch_rename_case_lower": "lowercase",
        "batch_rename_case_title": "Title Case",
        "batch_rename_case_camel": "camelCase",
        "batch_rename_case_snake": "snake_case",
        "batch_rename_include_ext": "Include Extension",
        "batch_rename_scope": "Scope",
        "batch_rename_scope_selected": "Selected Items",
        "batch_rename_scope_all": "All in Current Directory",
        "batch_rename_select_all": "Select All",
        "batch_rename_deselect_all": "Deselect All",
        "batch_rename_preview": "Preview",
        "batch_rename_original": "Original Name",
        "batch_rename_new": "New Name",
        "batch_rename_conflict": "Conflict",
        "batch_rename_no_change": "No Change",
        "batch_rename_apply": "Apply Rename",
        "batch_rename_cancel": "Cancel",
        "batch_rename_count": "%d items",
        "batch_rename_numbering_simple": "Simple",
        "batch_rename_numbering_template": "Template",
    ]

    @MainActor static func string(_ key: String) -> String {
        let lang = LanguageManager.shared.currentLanguage
        let dict = lang == "zh" ? zh : en
        return dict[key] ?? key
    }

    @MainActor static func string(_ key: String, _ args: CVarArg...) -> String {
        let template = string(key)
        return String(format: template, arguments: args)
    }
}
