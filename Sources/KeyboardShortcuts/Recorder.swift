#if os(macOS)
import SwiftUI

extension KeyboardShortcuts {
	private struct _Recorder: NSViewRepresentable { // swiftlint:disable:this type_name
		typealias NSViewType = RecorderCocoa

		let name: Name
		let onChange: ((_ shortcut: Shortcut?) -> Void)?
        let onInfoClicked: (()->Void)?

		func makeNSView(context: Context) -> NSViewType {
			.init(for: name, onChange: onChange, onInfoClicked: onInfoClicked)
		}

		func updateNSView(_ nsView: NSViewType, context: Context) {
			nsView.shortcutName = name
		}
	}

	/**
	A SwiftUI `View` that lets the user record a keyboard shortcut.

	You would usually put this in your settings window.

	It automatically prevents choosing a keyboard shortcut that is already taken by the system or by the app's main menu by showing a user-friendly alert to the user.

	It takes care of storing the keyboard shortcut in `UserDefaults` for you.

	```swift
	import SwiftUI
	import KeyboardShortcuts

	struct SettingsScreen: View {
		var body: some View {
			Form {
				KeyboardShortcuts.Recorder("Toggle Unicorn Mode:", name: .toggleUnicornMode)
			}
		}
	}
	```
	*/
    public struct Recorder<Label: View, Content:View>: View { // swiftlint:disable:this type_name
		private let name: Name
		private let onChange: ((Shortcut?) -> Void)?
        private let infoContent: (()->Content)?
		private let hasLabel: Bool
		private let label: Label
        @State private var showPopover = false

		init(
			for name: Name,
			onChange: ((Shortcut?) -> Void)? = nil,
            infoContent: (()->Content)?,
			hasLabel: Bool,
			@ViewBuilder label: () -> Label
		) {
			self.name = name
			self.onChange = onChange
            self.infoContent = infoContent
			self.hasLabel = hasLabel
			self.label = label()
		}

		public var body: some View {
			if hasLabel {
				if #available(macOS 13, *) {
					LabeledContent {
						_Recorder(
							name: name,
							onChange: onChange,
                            onInfoClicked: infoContent == nil ? nil : {
                                showPopover = true
                            }
						)
					} label: {
						label
					}
                    .popover(isPresented: $showPopover, content: { infoContent?() })
				} else {
					_Recorder(
						name: name,
						onChange: onChange,
                        onInfoClicked: infoContent == nil ? nil : {
                            showPopover = true
                        }
					)
                    .formLabel {
                        label
                    }
                    .popover(isPresented: $showPopover, content: { infoContent?() })
				}
			} else {
				_Recorder(
					name: name,
					onChange: onChange,
                    onInfoClicked: infoContent == nil ? nil : {
                        showPopover = true
                    }
				)
                .popover(isPresented: $showPopover, content: { infoContent?() })
			}
		}
	}
}

extension KeyboardShortcuts.Recorder<EmptyView, EmptyView> {
	/**
	- Parameter name: Strongly-typed keyboard shortcut name.
	- Parameter onChange: Callback which will be called when the keyboard shortcut is changed/removed by the user. This can be useful when you need more control. For example, when migrating from a different keyboard shortcut solution and you need to store the keyboard shortcut somewhere yourself instead of relying on the built-in storage. However, it's strongly recommended to just rely on the built-in storage when possible.
	*/
	public init(
		for name: KeyboardShortcuts.Name,
		onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil
	) {
		self.init(
			for: name,
			onChange: onChange,
			infoContent: nil,
			hasLabel: false
		) {}
	}
}

extension KeyboardShortcuts.Recorder<Text, EmptyView> {
	/**
	- Parameter title: The title of the keyboard shortcut recorder, describing its purpose.
	- Parameter name: Strongly-typed keyboard shortcut name.
	- Parameter onChange: Callback which will be called when the keyboard shortcut is changed/removed by the user. This can be useful when you need more control. For example, when migrating from a different keyboard shortcut solution and you need to store the keyboard shortcut somewhere yourself instead of relying on the built-in storage. However, it's strongly recommended to just rely on the built-in storage when possible.
	*/
	public init(
		_ title: LocalizedStringKey,
		name: KeyboardShortcuts.Name,
		onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil
	) {
		self.init(
			for: name,
			onChange: onChange,
			infoContent: nil,
			hasLabel: true
		) {
			Text(title)
		}
	}
}

extension KeyboardShortcuts.Recorder<Text, EmptyView> {
	/**
	- Parameter title: The title of the keyboard shortcut recorder, describing its purpose.
	- Parameter name: Strongly-typed keyboard shortcut name.
	- Parameter onChange: Callback which will be called when the keyboard shortcut is changed/removed by the user. This can be useful when you need more control. For example, when migrating from a different keyboard shortcut solution and you need to store the keyboard shortcut somewhere yourself instead of relying on the built-in storage. However, it's strongly recommended to just rely on the built-in storage when possible.
	*/
	@_disfavoredOverload
	public init(
		_ title: String,
		name: KeyboardShortcuts.Name,
		onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil
	) {
		self.init(
			for: name,
			onChange: onChange,
            infoContent: nil,
			hasLabel: true
		) {
			Text(title)
		}
	}
}

extension KeyboardShortcuts.Recorder {
	/**
	- Parameter name: Strongly-typed keyboard shortcut name.
	- Parameter onChange: Callback which will be called when the keyboard shortcut is changed/removed by the user. This can be useful when you need more control. For example, when migrating from a different keyboard shortcut solution and you need to store the keyboard shortcut somewhere yourself instead of relying on the built-in storage. However, it's strongly recommended to just rely on the built-in storage when possible.
	- Parameter label: A view that describes the purpose of the keyboard shortcut recorder.
	*/
	public init(
		for name: KeyboardShortcuts.Name,
		onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil,
        @ViewBuilder infoContent: @escaping ()->Content,
		@ViewBuilder label: () -> Label
	) {
		self.init(
			for: name,
			onChange: onChange,
            infoContent: infoContent,
			hasLabel: true,
			label: label
		)
	}
}

#Preview {
	KeyboardShortcuts.Recorder("record_shortcut", name: .init("xcodePreview"))
		.environment(\.locale, .init(identifier: "en"))
}

#Preview {
	KeyboardShortcuts.Recorder("record_shortcut", name: .init("xcodePreview"))
		.environment(\.locale, .init(identifier: "zh-Hans"))
}

#Preview {
	KeyboardShortcuts.Recorder("record_shortcut", name: .init("xcodePreview"))
		.environment(\.locale, .init(identifier: "ru"))
}
#endif
