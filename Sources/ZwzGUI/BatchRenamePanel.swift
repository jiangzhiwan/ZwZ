import SwiftUI
import ZwzCore

/// 批量重命名内嵌预览面板
struct ZWZBatchRenamePanel: View {
    @ObservedObject var viewModel: ArchiveViewModel
    let currentDirEntries: [ArchiveEntry]
    let onApply: ([(sourcePath: String, newName: String)]) -> Void
    let onCancel: () -> Void

    @State private var previewItems: [BatchRenameItem]?
    @State private var previewError: String?

    private var effectiveSelectedEntries: [ArchiveEntry] {
        if viewModel.batchRenameScopeAll {
            return currentDirEntries
        } else {
            return currentDirEntries.filter { viewModel.batchSelectedPaths.contains($0.path) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ruleConfigSection
            Divider()
            scopeAndSelectionSection
            Divider()
            previewSection
            Divider()
            actionButtons
        }
        .background(.ultraThinMaterial)
        .onAppear { updatePreview() }
    }

    // MARK: - Rule Configuration

    private var ruleConfigSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(L.string("batch_rename_rule"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)

                Picker("", selection: $viewModel.batchRenameRuleType) {
                    ForEach(BatchRenameRuleType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
                .onChange(of: viewModel.batchRenameRuleType) { _, _ in updatePreview() }

                Spacer()

                Toggle(isOn: $viewModel.batchRenameIncludeExtension) {
                    Text(L.string("batch_rename_include_ext"))
                        .font(.system(size: 11, design: .rounded))
                }
                .toggleStyle(.checkbox)
                .onChange(of: viewModel.batchRenameIncludeExtension) { _, _ in updatePreview() }
            }

            ruleParameterRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var ruleParameterRow: some View {
        switch viewModel.batchRenameRuleType {
        case .findReplace:
            HStack(spacing: 8) {
                labeledField(L.string("batch_rename_find"), text: $viewModel.batchFindText)
                labeledField(L.string("batch_rename_replace"), text: $viewModel.batchReplaceText)
            }
            .onChange(of: viewModel.batchFindText) { _, _ in updatePreview() }
            .onChange(of: viewModel.batchReplaceText) { _, _ in updatePreview() }

        case .prefixSuffix:
            HStack(spacing: 8) {
                labeledField(L.string("batch_rename_prefix"), text: $viewModel.batchPrefixText)
                labeledField(L.string("batch_rename_suffix"), text: $viewModel.batchSuffixText)
            }
            .onChange(of: viewModel.batchPrefixText) { _, _ in updatePreview() }
            .onChange(of: viewModel.batchSuffixText) { _, _ in updatePreview() }

        case .numbering:
            VStack(spacing: 8) {
                Picker("", selection: $viewModel.batchNumberingMode) {
                    ForEach(BatchNumberingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: viewModel.batchNumberingMode) { _, _ in updatePreview() }

                if viewModel.batchNumberingMode == .simple {
                    HStack(spacing: 8) {
                        labeledField(L.string("batch_rename_prefix"), text: $viewModel.batchNumberingPrefix)
                        labeledIntField(L.string("batch_rename_start"), value: $viewModel.batchNumberingStart)
                        labeledIntField(L.string("batch_rename_step"), value: $viewModel.batchNumberingStep)
                        labeledIntField(L.string("batch_rename_digits"), value: $viewModel.batchNumberingDigits)
                    }
                } else {
                    labeledField(L.string("batch_rename_template"), text: $viewModel.batchNumberingTemplate)
                        .onChange(of: viewModel.batchNumberingTemplate) { _, _ in updatePreview() }
                }
            }
            .onChange(of: viewModel.batchNumberingPrefix) { _, _ in updatePreview() }
            .onChange(of: viewModel.batchNumberingStart) { _, _ in updatePreview() }
            .onChange(of: viewModel.batchNumberingStep) { _, _ in updatePreview() }
            .onChange(of: viewModel.batchNumberingDigits) { _, _ in updatePreview() }

        case .regex:
            HStack(spacing: 8) {
                labeledField(L.string("batch_rename_pattern"), text: $viewModel.batchRegexPattern)
                labeledField(L.string("batch_rename_template"), text: $viewModel.batchRegexTemplate)
            }
            .onChange(of: viewModel.batchRegexPattern) { _, _ in updatePreview() }
            .onChange(of: viewModel.batchRegexTemplate) { _, _ in updatePreview() }

        case .caseConversion:
            Picker(L.string("batch_rename_case_mode"), selection: $viewModel.batchCaseMode) {
                Text(L.string("batch_rename_case_upper")).tag(CaseMode.upper)
                Text(L.string("batch_rename_case_lower")).tag(CaseMode.lower)
                Text(L.string("batch_rename_case_title")).tag(CaseMode.titleCase)
                Text(L.string("batch_rename_case_camel")).tag(CaseMode.camelCase)
                Text(L.string("batch_rename_case_snake")).tag(CaseMode.snakeCase)
            }
            .pickerStyle(.menu)
            .frame(width: 200)
            .onChange(of: viewModel.batchCaseMode) { _, _ in updatePreview() }
        }
    }

    // MARK: - Scope & Selection

    private var scopeAndSelectionSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text(L.string("batch_rename_scope"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)

                Picker("", selection: $viewModel.batchRenameScopeAll) {
                    Text(L.string("batch_rename_scope_selected")).tag(false)
                    Text(L.string("batch_rename_scope_all")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .onChange(of: viewModel.batchRenameScopeAll) { _, _ in
                    if viewModel.batchRenameScopeAll {
                        viewModel.batchSelectedPaths = Set(currentDirEntries.map(\.path))
                    }
                    updatePreview()
                }

                Spacer()

                if !viewModel.batchRenameScopeAll {
                    Button(L.string("batch_rename_select_all")) {
                        viewModel.batchSelectedPaths = Set(currentDirEntries.map(\.path))
                        updatePreview()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.zwzBlue)

                    Button(L.string("batch_rename_deselect_all")) {
                        viewModel.batchSelectedPaths = []
                        updatePreview()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.zwzBlue)
                }
            }

            if !viewModel.batchRenameScopeAll {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(currentDirEntries, id: \.path) { entry in
                            chip(for: entry)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 28)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func chip(for entry: ArchiveEntry) -> some View {
        let isSelected = viewModel.batchSelectedPaths.contains(entry.path)
        return Button {
            if isSelected {
                viewModel.batchSelectedPaths.remove(entry.path)
            } else {
                viewModel.batchSelectedPaths.insert(entry.path)
            }
            updatePreview()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 9))
                Text(entry.name)
                    .font(.system(size: 11, design: .rounded))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.zwzBlue.opacity(0.15) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.zwzBlue.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .foregroundColor(isSelected ? .zwzBlue : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preview Table

    private var previewSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string("batch_rename_preview"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                if let items = previewItems {
                    Text(L.string("batch_rename_count", items.count))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if let error = previewError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else if let items = previewItems, !items.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                            previewRow(item)
                        }
                    }
                }
                .frame(maxHeight: 200)
            } else {
                Text(L.string("batch_rename_no_change"))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }

    private func previewRow(_ item: BatchRenameItem) -> some View {
        let hasChange = item.originalName != item.finalName
        return HStack(spacing: 12) {
            Text(item.originalName)
                .font(.system(size: 11, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(hasChange ? .primary : .secondary)

            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            Text(item.finalName)
                .font(.system(size: 11, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(hasChange ? .zwzBlue : .secondary)

            if item.hasConflict {
                Text(L.string("batch_rename_conflict"))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(3)
            } else if !hasChange {
                Text(L.string("batch_rename_no_change"))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack {
            Spacer()
            Button(L.string("batch_rename_cancel")) {
                onCancel()
            }
            .zwzSheetButtonStyle(.secondary)

            Button(L.string("batch_rename_apply")) {
                applyBatchRename()
            }
            .zwzSheetButtonStyle(.pink)
            .disabled(previewItems?.isEmpty ?? true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Logic

    private func updatePreview() {
        let selected = effectiveSelectedEntries
        guard !selected.isEmpty else {
            previewItems = []
            previewError = nil
            return
        }
        if let items = viewModel.computeBatchRenamePreview(
            selectedEntries: selected,
            allEntriesInDir: currentDirEntries
        ) {
            previewItems = items
            previewError = nil
        } else {
            previewItems = nil
        }
    }

    private func applyBatchRename() {
        guard let items = previewItems else { return }
        let selected = effectiveSelectedEntries
        var renameItems: [(sourcePath: String, newName: String)] = []
        for (index, entry) in selected.enumerated() where index < items.count {
            let item = items[index]
            if item.originalName != item.finalName {
                renameItems.append((sourcePath: entry.path, newName: item.finalName))
            }
        }
        guard !renameItems.isEmpty else { return }
        onApply(renameItems)
    }

    // MARK: - Helpers

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .rounded))
        }
    }

    private func labeledIntField(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.secondary)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .rounded))
                .frame(width: 50)
        }
    }
}
