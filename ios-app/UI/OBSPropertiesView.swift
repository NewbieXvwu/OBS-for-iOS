/* SPDX-License-Identifier: GPL-2.0-or-later */
/* 自研必要性证明：原版 OBSPropertiesView 依赖 Qt Widgets，此处用 SwiftUI
 * 渲染相同的 obs_properties 元数据，沿用 libobs 回调和设置对象。 */

import SwiftUI
import UniformTypeIdentifiers
#if OBS_APP_PRIVILEGED
import ReplayKit
#endif

final class OBSPropertyEditor: ObservableObject {
    let properties: OpaquePointer
    let settings: OpaquePointer
    let deferred: Bool
    let source: OpaquePointer?
    private let update: (OpaquePointer) -> Void
    @Published private(set) var dirty = false

    init(properties: OpaquePointer, settings: OpaquePointer, source: OpaquePointer? = nil,
         update: @escaping (OpaquePointer) -> Void) {
        self.properties = properties
        self.source = obs_source_get_ref(source)
        self.settings = obs_data_get_defaults(settings)
        obs_data_apply(self.settings, settings)
        deferred = obs_properties_get_flags(properties) & UInt32(OBS_PROPERTIES_DEFER_UPDATE) != 0
        self.update = update
        obs_properties_apply_settings(properties, self.settings)
    }

    convenience init?(source: OpaquePointer) {
        guard let properties = obs_source_properties(source),
              let settings = obs_source_get_settings(source) else { return nil }
        defer { obs_data_release(settings) }
        self.init(properties: properties, settings: settings, source: source) {
            obs_source_update(source, $0)
            obs_frontend_save()
        }
    }

    deinit {
        obs_properties_destroy(properties)
        obs_data_release(settings)
        obs_source_release(source)
    }

    func changed(_ property: OpaquePointer) {
        _ = obs_property_modified(property, settings)
        if deferred { dirty = true } else { update(settings); objectWillChange.send() }
    }

    func apply() {
        update(settings)
        dirty = false
    }
}

struct OBSPropertiesView: View {
    @ObservedObject var editor: OBSPropertyEditor

    var body: some View {
        fields(editor.properties)
        if editor.deferred {
            Button(OBSLocale.str("Apply")) { editor.apply() }.disabled(!editor.dirty)
        }
    }

    private func fields(_ properties: OpaquePointer?) -> AnyView {
        var property = obs_properties_first(properties)
        var visible: [OpaquePointer] = []
        while let current = property {
            if obs_property_visible(current) { visible.append(current) }
            if !obs_property_next(&property) { break }
        }
        return AnyView(ForEach(visible, id: \.self) { property in
            OBSPropertyRow(property: property, editor: editor, children: {
                fields(obs_property_group_content(property))
            })
            .disabled(!obs_property_enabled(property))
        })
    }
}

private struct OBSPropertyRow<Children: View>: View {
    let property: OpaquePointer
    let editor: OBSPropertyEditor
    @ViewBuilder var children: () -> Children
    @State private var pickingFile = false
    @State private var importError: String?

    private var key: String { String(cString: obs_property_name(property)) }
    private var title: String { String(cString: obs_property_description(property)) }
    private var type: obs_property_type { obs_property_get_type(property) }
    private var settings: OpaquePointer { editor.settings }

    private var string: Binding<String> {
        bind({ String(cString: obs_data_get_string(settings, key)) },
             { obs_data_set_string(settings, key, $0) })
    }

    private var bool: Binding<Bool> {
        bind({ obs_data_get_bool(settings, key) }, { obs_data_set_bool(settings, key, $0) })
    }

    var body: some View {
        controls
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: contentTypes,
                          allowsMultipleSelection: type == OBS_PROPERTY_EDITABLE_LIST) { result in
                do {
                    for url in try result.get() {
                        let path = try localFile(url).path
                        if type == OBS_PROPERTY_EDITABLE_LIST { addItem(path) }
                        else { string.wrappedValue = path }
                    }
                } catch { importError = error.localizedDescription }
            }
            .alert(OBSLocale.str("PluginManager.Status.Error"), isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                    Button(OBSLocale.str("OK"), role: .cancel) { importError = nil }
                } message: { Text(importError ?? "") }
    }

    @ViewBuilder private var controls: some View {
        switch type {
        case OBS_PROPERTY_BOOL:
            Toggle(title, isOn: bool)
        case OBS_PROPERTY_INT, OBS_PROPERTY_FLOAT:
            number
        case OBS_PROPERTY_TEXT:
            switch obs_property_text_type(property) {
            case OBS_TEXT_PASSWORD:
                SecureField(title, text: string)
            case OBS_TEXT_MULTILINE:
                VStack(alignment: .leading) {
                    Text(title)
                    TextEditor(text: string)
                        .font(obs_property_text_monospace(property) ? .body.monospaced() : .body)
                        .frame(minHeight: 80)
                }
            case OBS_TEXT_INFO:
                Text(title)
                    .foregroundStyle(obs_property_text_info_type(property) == OBS_TEXT_INFO_ERROR ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                TextField(title, text: string)
            }
        case OBS_PROPERTY_PATH:
            HStack {
                TextField(title, text: string).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(OBSLocale.str("Browse")) { pickingFile = true }.buttonStyle(.borderless)
            }
        case OBS_PROPERTY_LIST:
            options
        case OBS_PROPERTY_COLOR, OBS_PROPERTY_COLOR_ALPHA:
            ColorPicker(title, selection: color, supportsOpacity: type == OBS_PROPERTY_COLOR_ALPHA)
        case OBS_PROPERTY_FONT:
            fontProperties
        case OBS_PROPERTY_EDITABLE_LIST:
            editableList
        case OBS_PROPERTY_FRAME_RATE:
            frameRate
        case OBS_PROPERTY_GROUP:
            if obs_property_group_type(property) == OBS_GROUP_CHECKABLE {
                Toggle(title, isOn: bool)
                VStack(alignment: .leading) { children() }.disabled(!bool.wrappedValue)
            } else {
                DisclosureGroup(title) { children() }
            }
        case OBS_PROPERTY_BUTTON:
            #if OBS_APP_PRIVILEGED
            if key == "broadcast", let source = editor.source,
               String(cString: obs_source_get_id(source)) == "ios_screen_capture" {
                HStack {
                    Text(title)
                    Spacer()
                    OBSBroadcastPicker {
                        obs_property_button_clicked(property, UnsafeMutableRawPointer(source))
                    }.frame(width: 44, height: 44)
                }
            } else { propertyButton }
            #else
            propertyButton
            #endif
        default:
            EmptyView()
        }
    }

    private var propertyButton: some View {
        Button(title) {
            if obs_property_button_type(property) == OBS_BUTTON_URL,
               let target = obs_property_button_url(property), let url = URL(string: String(cString: target)),
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            } else if obs_property_button_clicked(property, editor.source.map(UnsafeMutableRawPointer.init)) {
                editor.objectWillChange.send()
            }
        }
    }

    private func bind<Value>(_ get: @escaping () -> Value, _ set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: get, set: { value in set(value); editor.changed(property) })
    }

    private var number: some View {
        let integer = type == OBS_PROPERTY_INT
        let minimum = integer ? Double(obs_property_int_min(property)) : obs_property_float_min(property)
        let maximum = integer ? Double(obs_property_int_max(property)) : obs_property_float_max(property)
        let step = integer ? Double(obs_property_int_step(property)) : obs_property_float_step(property)
        let style = integer ? obs_property_int_type(property) : obs_property_float_type(property)
        let suffix = integer ? obs_property_int_suffix(property) : obs_property_float_suffix(property)
        let value = bind({
            integer ? Double(obs_data_get_int(settings, key)) : obs_data_get_double(settings, key)
        }, { input in
            let clamped = min(max(input, minimum), maximum)
            if integer { obs_data_set_int(settings, key, Int64(clamped.rounded())) }
            else { obs_data_set_double(settings, key, clamped) }
        })
        return VStack(alignment: .leading) {
            HStack {
                Text(title)
                TextField(title, value: value, format: .number.grouping(.never))
                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                if let suffix { Text(String(cString: suffix)) }
            }
            if style == OBS_NUMBER_SLIDER && minimum < maximum && step > 0 {
                Slider(value: value, in: minimum...maximum, step: step)
            }
        }
    }

    private func optionValue(_ index: Int) -> String {
        switch obs_property_list_format(property) {
        case OBS_COMBO_FORMAT_INT: String(obs_property_list_item_int(property, index))
        case OBS_COMBO_FORMAT_FLOAT: String(obs_property_list_item_float(property, index))
        case OBS_COMBO_FORMAT_BOOL: String(obs_property_list_item_bool(property, index))
        default: String(cString: obs_property_list_item_string(property, index))
        }
    }

    private var options: some View {
        let value = bind({
            switch obs_property_list_format(property) {
            case OBS_COMBO_FORMAT_INT: String(obs_data_get_int(settings, key))
            case OBS_COMBO_FORMAT_FLOAT: String(obs_data_get_double(settings, key))
            case OBS_COMBO_FORMAT_BOOL: String(obs_data_get_bool(settings, key))
            default: String(cString: obs_data_get_string(settings, key))
            }
        }, { value in
            switch obs_property_list_format(property) {
            case OBS_COMBO_FORMAT_INT: obs_data_set_int(settings, key, Int64(value) ?? 0)
            case OBS_COMBO_FORMAT_FLOAT: obs_data_set_double(settings, key, Double(value) ?? 0)
            case OBS_COMBO_FORMAT_BOOL: obs_data_set_bool(settings, key, value == "true")
            default: obs_data_set_string(settings, key, value)
            }
        })
        let indices = 0..<obs_property_list_item_count(property)
        return VStack(alignment: .leading) {
            if obs_property_list_type(property) == OBS_COMBO_TYPE_EDITABLE {
                TextField(title, text: value)
            }
            Picker(title, selection: value) {
                if !indices.contains(where: { optionValue($0) == value.wrappedValue }) {
                    Text(value.wrappedValue).tag(value.wrappedValue)
                }
                ForEach(indices, id: \.self) { index in
                    Text(String(cString: obs_property_list_item_name(property, index)))
                        .tag(optionValue(index))
                        .disabled(obs_property_list_item_disabled(property, index))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var color: Binding<Color> {
        bind({
            let rgba = UInt32(truncatingIfNeeded: obs_data_get_int(settings, key))
            func component(_ shift: UInt32) -> Double { Double((rgba >> shift) & 255) / 255 }
            return Color(red: component(0), green: component(8), blue: component(16),
                         opacity: type == OBS_PROPERTY_COLOR_ALPHA ? component(24) : 1)
        }, { color in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            func byte(_ value: CGFloat) -> Int64 { Int64((255 * min(max(value, 0), 1)).rounded()) }
            let rgba = byte(red) | (byte(green) << 8) | (byte(blue) << 16) | (byte(alpha) << 24)
            obs_data_set_int(settings, key, rgba)
        })
    }

    private func font<Value>(_ read: @escaping (OpaquePointer?) -> Value,
                             _ write: @escaping (OpaquePointer, Value) -> Void) -> Binding<Value> {
        bind({
            let font = obs_data_get_obj(settings, key)
            defer { obs_data_release(font) }
            return read(font)
        }, { value in
            let font = obs_data_get_obj(settings, key) ?? obs_data_create()!
            write(font, value)
            obs_data_set_obj(settings, key, font)
            obs_data_release(font)
        })
    }

    private var fontProperties: some View {
        let face = font({ String(cString: obs_data_get_string($0, "face")) },
                        { obs_data_set_string($0, "face", $1); obs_data_set_string($0, "style", "") })
        let style = font({ String(cString: obs_data_get_string($0, "style")) },
                         { obs_data_set_string($0, "style", $1) })
        let size = font({ obs_data_get_int($0, "size") }, { obs_data_set_int($0, "size", max($1, 1)) })
        return VStack(alignment: .leading) {
            Picker(title, selection: face) {
                let families = UIFont.familyNames.sorted()
                if !families.contains(face.wrappedValue) { Text(face.wrappedValue).tag(face.wrappedValue) }
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            Picker(OBSLocale.str("Basic.Settings.Appearance.General.Variant"), selection: style) {
                Text(OBSLocale.str("Default")).tag("")
                let styles = UIFont.fontNames(forFamilyName: face.wrappedValue)
                if !style.wrappedValue.isEmpty && !styles.contains(style.wrappedValue) {
                    Text(style.wrappedValue).tag(style.wrappedValue)
                }
                ForEach(styles, id: \.self) { Text($0).tag($0) }
            }
            TextField(OBSLocale.str("Basic.TransformWindow.Size"), value: size, format: .number)
                .keyboardType(.numberPad)
        }
    }

    private func withArray<Result>(_ body: (OpaquePointer) -> Result) -> Result {
        let array = obs_data_get_array(settings, key) ?? obs_data_array_create()!
        defer { obs_data_array_release(array) }
        return body(array)
    }

    private func changeArray(_ change: (OpaquePointer) -> Void) {
        withArray { array in
            change(array)
            obs_data_set_array(settings, key, array)
            editor.changed(property)
        }
    }

    private func addItem(_ text: String) {
        changeArray { array in
            let item = obs_data_create()
            obs_data_set_string(item, "value", text)
            obs_data_array_push_back(array, item)
            obs_data_release(item)
        }
    }

    private var editableList: some View {
        let count = withArray { obs_data_array_count($0) }
        let listType = obs_property_editable_list_type(property)
        return VStack(alignment: .leading) {
            Text(title)
            ForEach(0..<count, id: \.self) { index in
                HStack {
                    TextField(title, text: Binding(get: {
                        withArray { array in
                            let item = obs_data_array_item(array, index)
                            defer { obs_data_release(item) }
                            return String(cString: obs_data_get_string(item, "value"))
                        }
                    }, set: { value in
                        changeArray { array in
                            let item = obs_data_array_item(array, index)
                            obs_data_set_string(item, "value", value)
                            obs_data_release(item)
                        }
                    })).autocorrectionDisabled()
                    Button {
                        moveItem(index, to: index - 1)
                    } label: {
                        Label(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveUp"), systemImage: "chevron.up")
                    }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(index == 0)
                    Button {
                        moveItem(index, to: index + 1)
                    } label: {
                        Label(OBSLocale.menu("Basic.MainMenu.Edit.Order.MoveDown"), systemImage: "chevron.down")
                    }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(index + 1 == count)
                    Button {
                        changeArray { obs_data_array_erase($0, index) }
                    } label: {
                        Label(OBSLocale.str("Remove"), systemImage: "minus.circle")
                    }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            HStack {
                if listType != OBS_EDITABLE_LIST_TYPE_FILES {
                    Button(OBSLocale.str("Add")) { addItem("") }.buttonStyle(.borderless)
                }
                if listType != OBS_EDITABLE_LIST_TYPE_STRINGS {
                    Button(OBSLocale.str("Browse")) { pickingFile = true }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func moveItem(_ index: Int, to destination: Int) {
        changeArray { array in
            guard let item = obs_data_array_item(array, index) else { return }
            obs_data_array_erase(array, index)
            obs_data_array_insert(array, destination, item)
            obs_data_array_release(item)
        }
    }

    private var frameRate: some View {
        func read() -> (media_frames_per_second, String) {
            var fps = media_frames_per_second(numerator: 30, denominator: 1)
            var option: UnsafePointer<CChar>?
            _ = obs_data_get_frames_per_second(settings, key, &fps, &option)
            return (fps, option.map { String(cString: $0) } ?? "")
        }
        let custom = bind({ read().1 }, { option in
            obs_data_set_frames_per_second(settings, key, read().0, option.isEmpty ? nil : option)
        })
        let numerator = bind({ read().0.numerator }, { value in
            var fps = read().0
            fps.numerator = max(value, 1)
            fps.denominator = max(fps.denominator, 1)
            obs_data_set_frames_per_second(settings, key, fps, nil)
        })
        let denominator = bind({ read().0.denominator }, { value in
            var fps = read().0
            fps.denominator = max(value, 1)
            fps.numerator = max(fps.numerator, 1)
            obs_data_set_frames_per_second(settings, key, fps, nil)
        })
        return VStack(alignment: .leading) {
            Picker(title, selection: custom) {
                Text(OBSLocale.str("Basic.Settings.Accessibility.ColorOverrides.Preset.Custom")).tag("")
                ForEach(0..<obs_property_frame_rate_options_count(property), id: \.self) { index in
                    Text(String(cString: obs_property_frame_rate_option_description(property, index)))
                        .tag(String(cString: obs_property_frame_rate_option_name(property, index)))
                }
            }
            if custom.wrappedValue.isEmpty {
                HStack {
                    TextField(OBSLocale.str("Basic.Settings.Video.Numerator"), value: numerator, format: .number)
                    Text("/")
                    TextField(OBSLocale.str("Basic.Settings.Video.Denominator"), value: denominator, format: .number)
                }.keyboardType(.numberPad)
            }
        }
    }

    private var contentTypes: [UTType] {
        guard type == OBS_PROPERTY_PATH || type == OBS_PROPERTY_EDITABLE_LIST else { return [.item] }
        if type == OBS_PROPERTY_PATH && obs_property_path_type(property) == OBS_PATH_DIRECTORY { return [.folder] }
        let filter = type == OBS_PROPERTY_PATH ? obs_property_path_filter(property) :
            obs_property_editable_list_filter(property)
        guard let filter else { return [.item] }
        let text = String(cString: filter)
        if text.contains("(*.*)") { return [.item] }
        let extensions = text.components(separatedBy: .init(charactersIn: " ();"))
            .filter { $0.hasPrefix("*.") }
            .compactMap { UTType(filenameExtension: String($0.dropFirst(2))) }
        return extensions.isEmpty ? [.item] : extensions
    }

    private func localFile(_ url: URL) throws -> URL {
        guard !url.path.hasPrefix(NSHomeDirectory() + "/") else { return url }
        let accessible = url.startAccessingSecurityScopedResource()
        defer { if accessible { url.stopAccessingSecurityScopedResource() } }
        let directory = URL.documentsDirectory.appendingPathComponent("OBS Media/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}

#if OBS_APP_PRIVILEGED
private struct OBSBroadcastPicker: UIViewRepresentable {
    let start: () -> Bool

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = "org.obsproject.studio.ios.broadcast"
        picker.showsMicrophoneButton = false
        picker.isUserInteractionEnabled = start()
        return picker
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
#endif

struct SourcePropertiesView: View {
    let source: SourceReference
    @State private var editor: OBSPropertyEditor?

    var body: some View {
        Form {
            if let editor { OBSPropertiesView(editor: editor) }
        }
        .navigationTitle(OBSLocale.str("Properties") + " — " + source.name)
        .onAppear {
            editor = withSource(source.id, OBSPropertyEditor.init(source:)) ?? nil
        }
    }
}

private final class FilterCollector {
    var filters: [SourceReference] = []
}

private func collectFilter(_ source: OpaquePointer?, _ filter: OpaquePointer?, _ data: UnsafeMutableRawPointer?) {
    guard let filter, let data else { return }
    Unmanaged<FilterCollector>.fromOpaque(data).takeUnretainedValue().filters.append(SourceReference(filter))
}

struct SourceFiltersView: View {
    let source: SourceReference
    @State private var filters: [SourceReference] = []
    @State private var selection: SourceReference?
    @State private var editor: OBSPropertyEditor?
    @State private var kinds: [SourceKind] = []

    var body: some View {
        Form {
            Section(OBSLocale.str("Filters")) {
                ForEach(filters) { filter in
                    Button {
                        select(filter)
                    } label: {
                        HStack {
                            Text(filter.name)
                            Spacer()
                            if filter == selection { Image(systemName: "checkmark") }
                        }
                    }
                    .contextMenu {
                        Button(OBSLocale.str("MoveUp")) { order(filter, OBS_ORDER_MOVE_UP) }
                        Button(OBSLocale.str("MoveDown")) { order(filter, OBS_ORDER_MOVE_DOWN) }
                        Button(OBSLocale.str("Remove"), role: .destructive) {
                            withSource(source.id) { parent in
                                withSource(filter.id) { obs_source_filter_remove(parent, $0) }
                            }
                            if selection == filter { select(nil) }
                            refresh()
                        }
                    }
                }
                Menu(OBSLocale.str("Add")) {
                    ForEach(kinds) { kind in
                        Button(kind.name) {
                            withSource(source.id) { parent in
                                guard let filter = obs_source_create(kind.id, kind.name, nil, nil) else { return }
                                obs_source_filter_add(parent, filter)
                                select(SourceReference(filter))
                                obs_source_release(filter)
                            }
                            refresh()
                        }
                    }
                }
            }
            if let editor, let selection {
                Section(selection.name) { OBSPropertiesView(editor: editor).id(selection.id) }
            }
        }
        .navigationTitle(OBSLocale.str("Filters") + " — " + source.name)
        .onAppear {
            refresh()
            let parentFlags = withSource(source.id, obs_source_get_output_flags) ?? 0
            var index = 0
            var id: UnsafePointer<CChar>?
            var available: [SourceKind] = []
            while obs_enum_filter_types(index, &id) {
                defer { index += 1 }
                guard let id, let name = obs_source_get_display_name(id) else { continue }
                let flags = obs_get_source_output_flags(id)
                guard flags & UInt32(OBS_SOURCE_CAP_DISABLED | OBS_SOURCE_CAP_OBSOLETE) == 0,
                      flags & UInt32(OBS_SOURCE_AUDIO | OBS_SOURCE_VIDEO) & ~parentFlags == 0 else { continue }
                available.append(SourceKind(id: String(cString: id), name: String(cString: name)))
            }
            kinds = available.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            select(filters.first)
        }
    }

    private func select(_ filter: SourceReference?) {
        selection = filter
        editor = filter.flatMap { withSource($0.id, OBSPropertyEditor.init(source:)) ?? nil }
    }

    private func order(_ filter: SourceReference, _ order: obs_order_movement) {
        withSource(source.id) { parent in
            withSource(filter.id) { obs_source_filter_set_order(parent, $0, order) }
        }
        refresh()
    }

    private func refresh() {
        let collector = FilterCollector()
        withSource(source.id) {
            obs_source_enum_filters($0, collectFilter, Unmanaged.passUnretained(collector).toOpaque())
        }
        filters = collector.filters
        obs_frontend_save()
    }
}
