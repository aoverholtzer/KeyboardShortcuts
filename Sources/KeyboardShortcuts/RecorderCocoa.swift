import Cocoa
import Carbon.HIToolbox

extension KeyboardShortcuts {
	/**
	A `NSView` that lets the user record a keyboard shortcut.

	You would usually put this in your preferences window.

	It automatically prevents choosing a keyboard shortcut that is already taken by the system or by the app's main menu by showing a user-friendly alert to the user.

	It takes care of storing the keyboard shortcut in `UserDefaults` for you.

	```swift
	import Cocoa
	import KeyboardShortcuts

	final class PreferencesViewController: NSViewController {
		override func loadView() {
			view = NSView()

			let recorder = KeyboardShortcuts.RecorderCocoa(for: .toggleUnicornMode)
			view.addSubview(recorder)
		}
	}
	```
	*/
	public final class RecorderCocoa: NSSearchField, NSSearchFieldDelegate {
		private let minimumWidth: Double = 120
		private var eventMonitor: LocalEventMonitor?
		private let onChange: ((_ shortcut: Shortcut?) -> Void)?
        private let onInfoClicked: (() -> Void)?
		private var observer: NSObjectProtocol?
		private var canBecomeKey = false

		/**
		The shortcut name for the recorder.

		Can be dynamically changed at any time.
		*/
		public var shortcutName: Name {
			didSet {
//				guard shortcutName != oldValue else {
//					return
//				}

				setStringValue(name: shortcutName)

				// This doesn't seem to be needed anymore, but I cannot test on older OS versions, so keeping it just in case.
				if #unavailable(macOS 12) {
					DispatchQueue.main.async { [self] in
						// Prevents the placeholder from being cut off.
						blur()
					}
				}
			}
		}

		/// :nodoc:
		override public var canBecomeKeyView: Bool { canBecomeKey }

		/// :nodoc:
		override public var intrinsicContentSize: CGSize {
			var size = super.intrinsicContentSize
			size.width = minimumWidth
			return size
		}

		private var cancelButton: NSButtonCell?
        
        private lazy var infoButton: NSButtonCell? = {
            if #available(macOS 11.0, *) {
                let button = NSButtonCell(imageCell: NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: "info")!)
                button.target = self
                button.action = #selector(showInfo)
//                button.bezelStyle = cancelButton?.bezelStyle ?? .circular
                button.isBordered = false
                button.isBezeled = false
                return button
            } else {
                return nil
            }
        }()
        
        @objc private func showInfo() {
            blur()
            onInfoClicked?()
        }

        private func updateCancelButton() {
//            !stringValue.isEmpty && getShortcut(for: shortcutName)?.isDefault != true
            if let shortcut = getShortcut(for: shortcutName),
               shortcut.isDefault == true {
                (cell as? NSSearchFieldCell)?.cancelButtonCell = onInfoClicked == nil ? nil : infoButton
            } else {
                (cell as? NSSearchFieldCell)?.cancelButtonCell = stringValue.isEmpty ? nil : cancelButton
            }
        }
//		private var showsCancelButton: Bool {
//			get { (cell as? NSSearchFieldCell)?.cancelButtonCell != nil }
//			set {
//				(cell as? NSSearchFieldCell)?.cancelButtonCell = newValue ? cancelButton : nil
//			}
//		}

		/**
		- Parameter name: Strongly-typed keyboard shortcut name.
		- Parameter onChange: Callback which will be called when the keyboard shortcut is changed/removed by the user. This can be useful when you need more control. For example, when migrating from a different keyboard shortcut solution and you need to store the keyboard shortcut somewhere yourself instead of relying on the built-in storage. However, it's strongly recommended to just rely on the built-in storage when possible.
		*/
		public required init(
			for name: Name,
			onChange: ((_ shortcut: Shortcut?) -> Void)? = nil,
            onInfoClicked: (()->Void)? = nil
		) {
			self.shortcutName = name
			self.onChange = onChange
            self.onInfoClicked = onInfoClicked

			super.init(frame: .zero)
			self.delegate = self
			self.placeholderString = "record_shortcut".localized
			self.alignment = .center
			(cell as? NSSearchFieldCell)?.searchButtonCell = nil

			self.wantsLayer = true
			self.translatesAutoresizingMaskIntoConstraints = false
			setContentHuggingPriority(.defaultHigh, for: .vertical)
			setContentHuggingPriority(.defaultLow, for: .horizontal)
			widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true

			// Hide the cancel button when not showing the shortcut so the placeholder text is properly centered. Must be last.
			self.cancelButton = (cell as? NSSearchFieldCell)?.cancelButtonCell
            
            allowsDefaultTighteningForTruncation = true
//            self.cancelButton?.bezelStyle = .texturedRounded
//            isBezeled = false
//            isBordered = false
//            bezelStyle = .squareBezel
//            drawsBackground = false
           // wantsLayer = true
           // layer?.opacity = 0.8
//            layer?.cornerRadius = 5
//            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.216).cgColor
//            layer?.borderWidth = 1

			setStringValue(name: name)

			setUpEvents()
		}

		@available(*, unavailable)
		public required init?(coder: NSCoder) {
			fatalError("init(coder:) has not been implemented")
		}

		private func setStringValue(name: KeyboardShortcuts.Name) {
			let shortcut = getShortcut(for: shortcutName)
            stringValue = shortcut.map { "\($0)" } ?? ""

			// If `stringValue` is empty, hide the cancel button to let the placeholder center.
//            showsCancelButton = !stringValue.isEmpty && shortcut?.isDefault != true
            updateCancelButton()
		}

		private func setUpEvents() {
			observer = NotificationCenter.default.addObserver(forName: .shortcutByNameDidChange, object: nil, queue: nil) { [weak self] notification in
				guard
					let self = self,
					let nameInNotification = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
					nameInNotification == self.shortcutName
				else {
					return
				}

				self.setStringValue(name: nameInNotification)
			}
		}

		/// :nodoc:
		public func controlTextDidChange(_ object: Notification) {
			if stringValue.isEmpty {
				saveShortcut(nil)
			}

//			showsCancelButton = !stringValue.isEmpty && getShortcut(for: shortcutName)?.isDefault != true
            updateCancelButton()
			if stringValue.isEmpty {
				// Hack to ensure that the placeholder centers after the above `showsCancelButton` setter.
				focus()
			}
		}

		/// :nodoc:
		public func controlTextDidEndEditing(_ object: Notification) {
			eventMonitor = nil
			placeholderString = "record_shortcut".localized
//			showsCancelButton = !stringValue.isEmpty && getShortcut(for: shortcutName)?.isDefault != true
            updateCancelButton()
			KeyboardShortcuts.isPaused = false
            
            if stringValue.isEmpty, let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName) {
                // if control is blank (no shortcut set) but we have a shortcut (e.g., a default),
                // then update control with that shortcut
                self.stringValue = "\(shortcut)"
//                self.showsCancelButton = shortcut.isDefault != true
                updateCancelButton()
            }
		}

		// Prevent the control from receiving the initial focus.
		/// :nodoc:
		override public func viewDidMoveToWindow() {
			guard window != nil else {
				return
			}

			canBecomeKey = true
		}

		/// :nodoc:
		override public func becomeFirstResponder() -> Bool {
			let shouldBecomeFirstResponder = super.becomeFirstResponder()

			guard shouldBecomeFirstResponder else {
				return shouldBecomeFirstResponder
			}

			placeholderString = "press_shortcut".localized
//			showsCancelButton = !stringValue.isEmpty && getShortcut(for: shortcutName)?.isDefault != true
            updateCancelButton()
			hideCaret()
			KeyboardShortcuts.isPaused = true // The position here matters.

			eventMonitor = LocalEventMonitor(events: [.keyDown, .leftMouseUp, .rightMouseUp]) { [weak self] event in
				guard let self = self else {
					return nil
				}

				let clickPoint = self.convert(event.locationInWindow, from: nil)
				let clickMargin = 3.0

				if
					event.type == .leftMouseUp || event.type == .rightMouseUp,
					!self.bounds.insetBy(dx: -clickMargin, dy: -clickMargin).contains(clickPoint)
				{
					self.blur()
					return nil
				}

				guard event.isKeyEvent else {
					return nil
				}

				if
					event.modifiers.isEmpty,
					event.specialKey == .tab
				{
					self.blur()

					// We intentionally bubble up the event so it can focus the next responder.
					return event
				}

				if
					event.modifiers.isEmpty,
					event.keyCode == kVK_Escape // TODO: Make this strongly typed.
				{
					self.blur()
					return nil
				}

				if
					event.modifiers.isEmpty,
					event.specialKey == .delete
						|| event.specialKey == .deleteForward
						|| event.specialKey == .backspace
				{
					self.clear()
					return nil
				}

				// The “shift” key is not allowed without other modifiers or a function key, since it doesn't actually work.
				guard
					!event.modifiers.subtracting(.shift).isEmpty
                        || event.specialKey?.isFunctionKey == true
                        || event.keyCode == kVK_JIS_Eisu || event.keyCode == kVK_JIS_Kana,
					let shortcut = Shortcut(event: event)
				else {
					NSSound.beep()
					return nil
				}

				if let menuItem = shortcut.takenByMainMenu {
					// TODO: Find a better way to make it possible to dismiss the alert by pressing "Enter". How can we make the input automatically temporarily lose focus while the alert is open?
					self.blur()

					NSAlert.showModal(
						for: self.window,
						title: String.localizedStringWithFormat("keyboard_shortcut_used_by_menu_item".localized, menuItem.title)
					)

					self.focus()

					return nil
				}

				guard !shortcut.isTakenBySystem else {
					self.blur()

					NSAlert.showModal(
						for: self.window,
						title: "keyboard_shortcut_used_by_system".localized,
						// TODO: Add button to offer to open the relevant system preference pane for the user.
						message: "keyboard_shortcuts_can_be_changed".localized
					)

					self.focus()

					return nil
				}

				self.stringValue = "\(shortcut)"
//				self.showsCancelButton = shortcut.isDefault != true
                self.updateCancelButton()

				self.saveShortcut(shortcut)
				self.blur()

				return nil
			}.start()

			return shouldBecomeFirstResponder
		}

		private func saveShortcut(_ shortcut: Shortcut?) {
			setShortcut(shortcut, for: shortcutName)
			onChange?(shortcut)
		}
	}
}
