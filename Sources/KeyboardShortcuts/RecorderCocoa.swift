
#if os(macOS)
import AppKit
import Carbon.HIToolbox

/// Enforces hiding the clear button on macOS 27, where clearing `cancelButtonCell` alone no
/// longer suppresses it. `cancelButtonRectForBounds:` is documented as a custom-layout hook, so
/// returning an empty rect keeps the button from being laid out or hit-tested.
private final class RecorderSearchFieldCell: NSSearchFieldCell {
	override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
		guard (controlView as? KeyboardShortcuts.RecorderCocoa)?.hidesCancelButton == true else {
			return super.cancelButtonRect(forBounds: rect)
		}

		return .zero
	}
}

extension KeyboardShortcuts {
	/**
	A `NSView` that lets the user record a keyboard shortcut.

	You would usually put this in your settings window.

	It automatically prevents choosing a keyboard shortcut that is already taken by the system or by the app's main menu by showing a user-friendly alert to the user.

	It takes care of storing the keyboard shortcut in `UserDefaults` for you.

	```swift
	import AppKit
	import KeyboardShortcuts

	final class SettingsViewController: NSViewController {
		override func loadView() {
			view = NSView()

			let recorder = KeyboardShortcuts.RecorderCocoa(for: .toggleUnicornMode)
			view.addSubview(recorder)
		}
	}
	```
	*/
	public final class RecorderCocoa: NSSearchField, NSSearchFieldDelegate {
		private let minimumWidth = 130.0
		private let onChange: ((_ shortcut: Shortcut?) -> Void)?
        private let onInfoClicked: (() -> Void)?
        private var observers:[NSObjectProtocol]?
		private var canBecomeKey = false
		private var eventMonitor: LocalEventMonitor?
//		private var shortcutsNameChangeObserver: NSObjectProtocol?
		private var windowDidResignKeyObserver: NSObjectProtocol?
		private var windowDidBecomeKeyObserver: NSObjectProtocol?

		/**
		The shortcut name for the recorder.

		Can be dynamically changed at any time.
		*/
		public var shortcutName: Name {
			didSet {
				guard shortcutName != oldValue else {
					return
				}

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
            let buttonCell: NSButtonCell?

            if let shortcut = getShortcut(for: shortcutName),
               shortcut.isDefault == true {
                buttonCell = onInfoClicked == nil ? nil : infoButton
            } else {
                buttonCell = stringValue.isEmpty ? nil : cancelButton
            }

            // Set this *before* installing the cell, since the assignment triggers layout.
            //
            // Clearing `cancelButtonCell` is the only thing that used to hide the button, but as
            // of macOS 27 AppKit appears to keep drawing its own clear button regardless — the
            // same way `centersPlaceholder` was quietly turned into a no-op in macOS 12. So also
            // zero out the button's layout rect, which is the documented subclass hook for it.
            // Belt and braces: on macOS 26 and earlier the assignment below is what does the
            // work, and the rect override is inert.
            hidesCancelButton = buttonCell == nil
            (cell as? NSSearchFieldCell)?.cancelButtonCell = buttonCell
            needsLayout = true
            needsDisplay = true
        }

        /// Whether the field is currently meant to show no button at all. Read by
        /// `RecorderSearchFieldCell` and by the `cancelButtonBounds` override.
        fileprivate var hidesCancelButton = false

        @_documentation(visibility: private)
        override public class var cellClass: AnyClass? {
            get { RecorderSearchFieldCell.self }
            set {} // swiftlint:disable:this unused_setter_value
        }

        @available(macOS 11.0, *)
        @_documentation(visibility: private)
        override public var cancelButtonBounds: NSRect {
            hidesCancelButton ? .zero : super.cancelButtonBounds
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

			// Use a default frame that matches our intrinsic size to prevent zero-size issues
			// when added without constraints (issue #209)
			super.init(frame: NSRect(x: 0, y: 0, width: minimumWidth, height: 24))
			self.delegate = self
			self.placeholderString = "record_shortcut".localized
			self.alignment = .center
			(cell as? NSSearchFieldCell)?.searchButtonCell = nil

			self.wantsLayer = true
			setContentHuggingPriority(.defaultHigh, for: .vertical)
			setContentHuggingPriority(.defaultHigh, for: .horizontal)

			// Hide the cancel button when not showing the shortcut so the placeholder text is properly centered. Must be last.
			self.cancelButton = (cell as? NSSearchFieldCell)?.cancelButtonCell

            allowsDefaultTighteningForTruncation = true

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
			observers = [
				NotificationCenter.default.addObserver(forName: .shortcutByNameDidChange, object: nil, queue: nil) { [weak self] notification in
					guard
						let self,
						let nameInNotification = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
						nameInNotification == shortcutName
					else {
						return
					}

					setStringValue(name: nameInNotification)
				},
                DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: nil) { [weak self] notification in
                    guard let self = self else { return }
                    self.setStringValue(name: self.shortcutName)
                },
            ]
		}

		private func endRecording() {
			eventMonitor = nil
			placeholderString = "record_shortcut".localized
//			showsCancelButton = !stringValue.isEmpty
            updateCancelButton()
			restoreCaret()
            KeyboardShortcuts.isPaused = false
            
            if stringValue.isEmpty, let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName) {
                // if control is blank (no shortcut set) but we have a shortcut (e.g., a default),
                // then update control with that shortcut
                self.stringValue = "\(shortcut)"
                updateCancelButton()
            }

			NotificationCenter.default.post(name: .recorderActiveStatusDidChange, object: nil, userInfo: ["isActive": false])
		}

		private func preventBecomingKey() {
			canBecomeKey = false

			// Prevent the control from receiving the initial focus.
			DispatchQueue.main.async { [self] in
				canBecomeKey = true
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
			// AppKit posts this spuriously while editing is still active. `becomeFirstResponder`
			// updates the cancel button, which mutates the cell's `cancelButtonCell` with the field
			// editor installed; that ends and restarts editing, and the resulting notification can
			// land *after* the key monitor is armed — tearing it down microseconds later. The
			// recorder then looks focused but captures nothing, and keystrokes fall through to the
			// search field as plain text.
			//
			// Deciding synchronously is not reliable in either direction: on the spurious
			// notification the field editor is still installed, but on a genuine one AppKit has
			// not necessarily moved first responder yet. Re-check on the next turn, once things
			// have settled — by then a spurious end has already restarted editing, while a real
			// one has left `currentEditor()` nil.
			Task { @MainActor [weak self] in
				guard let self else {
					return
				}

				if let editor = currentEditor(), window?.firstResponder === editor {
					return
				}

				endRecording()
			}
		}

		/// :nodoc:
		override public func viewDidMoveToWindow() {
			guard let window else {
				windowDidResignKeyObserver = nil
				windowDidBecomeKeyObserver = nil
				endRecording()
				return
			}

			// Ensures the recorder stops when the window is hidden.
			// This is especially important for Settings windows, which as of macOS 13.5, only hides instead of closes when you click the close button.
			windowDidResignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { [weak self] _ in
				guard
					let self,
					let window = self.window
				else {
					return
				}

				endRecording()
				window.makeFirstResponder(nil)
			}

			// Ensures the recorder does not receive initial focus when a hidden window becomes unhidden.
			windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil) { [weak self] _ in
				self?.preventBecomingKey()
			}

			preventBecomingKey()
		}

		/// :nodoc:
		override public func becomeFirstResponder() -> Bool {
			// Ensure we have a valid window before attempting to become first responder
			// This prevents issues in SwiftUI contexts where the view hierarchy might not be fully established
			guard window != nil else {
				return false
			}

			let shouldBecomeFirstResponder = super.becomeFirstResponder()

			guard shouldBecomeFirstResponder else {
				return shouldBecomeFirstResponder
			}

			placeholderString = "press_shortcut".localized
//			showsCancelButton = !stringValue.isEmpty && getShortcut(for: shortcutName)?.isDefault != true
            updateCancelButton()
			hideCaret()
			KeyboardShortcuts.isPaused = true // The position here matters.
			NotificationCenter.default.post(name: .recorderActiveStatusDidChange, object: nil, userInfo: ["isActive": true])

			eventMonitor = LocalEventMonitor(events: [.keyDown, .leftMouseUp, .rightMouseUp]) { [weak self] event in
				guard let self else {
					return nil
				}

				let clickPoint = convert(event.locationInWindow, from: nil)
				let clickMargin = 3.0

				if event.type == .leftMouseUp || event.type == .rightMouseUp {
					guard bounds.insetBy(dx: -clickMargin, dy: -clickMargin).contains(clickPoint) else {
						blur()
						return event
					}

					// A click *inside* the field must be passed through, not swallowed. It used to
					// fall through to the `isKeyEvent` guard below and get consumed, which killed
					// the buttons in the field: `NSSearchFieldCell` completes `_searchFieldCancel:`
					// on mouseUp, so the X (and the info button, which is installed in the same
					// slot) could be pressed but never fired.
					return event
				}

				guard event.isKeyEvent else {
					return nil
				}

				if
					event.modifiers.isEmpty,
					event.specialKey == .tab
				{
					blur()

					// We intentionally bubble up the event so it can focus the next responder.
					return event
				}

				if
					event.modifiers.isEmpty,
					event.keyCode == kVK_Escape // TODO: Make this strongly typed.
				{
					blur()
					return nil
				}

				if
					event.modifiers.isEmpty,
					event.specialKey == .delete
						|| event.specialKey == .deleteForward
						|| event.specialKey == .backspace
				{
					clear()
					return nil
				}

				// The “shift” key is not allowed without other modifiers or a function key, since it doesn't actually work.
				guard
					!event.modifiers.subtracting([.shift, .function]).isEmpty
						|| event.specialKey?.isFunctionKey == true,
					let shortcut = Shortcut(event: event)
				else {
					NSSound.beep()
					return nil
				}

				if let menuItem = shortcut.takenByMainMenu {
					// TODO: Find a better way to make it possible to dismiss the alert by pressing "Enter". How can we make the input automatically temporarily lose focus while the alert is open?
					blur()

					NSAlert.showModal(
						for: window,
						title: String.localizedStringWithFormat("keyboard_shortcut_used_by_menu_item".localized, menuItem.title)
					)

					focus()

					return nil
				}

				// See: https://developer.apple.com/forums/thread/763878?answerId=804374022#804374022
				if shortcut.isDisallowed {
					blur()

					NSAlert.showModal(
						for: window,
						title: "keyboard_shortcut_disallowed".localized
					)

					focus()
					return nil
				}

				if shortcut.isTakenBySystem {
					blur()

					let modalResponse = NSAlert.showModal(
						for: window,
						title: "keyboard_shortcut_used_by_system".localized,
						// TODO: Add button to offer to open the relevant system settings pane for the user.
						message: "keyboard_shortcuts_can_be_changed".localized,
						buttonTitles: [
							"ok".localized,
							"force_use_shortcut".localized
						]
					)

					focus()

					// If the user has selected "Use Anyway" in the dialog (the second option), we'll continue setting the keyboard shorcut even though it's reserved by the system.
					guard modalResponse == .alertSecondButtonReturn else {
						return nil
					}
				}

				stringValue = "\(shortcut)"
//				showsCancelButton = shortcut.isDefault != true
                updateCancelButton()

				saveShortcut(shortcut)
				blur()

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

extension Notification.Name {
	static let recorderActiveStatusDidChange = Self("KeyboardShortcuts_recorderActiveStatusDidChange")
}
#endif
