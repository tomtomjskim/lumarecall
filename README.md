# LumaRecall

Dim all active displays with one command, then restore each display's previous brightness. This small Swift utility talks directly to macOS and runs without a companion app or third-party libraries.

## Build and install

Install Apple's Xcode Command Line Tools if `xcrun swiftc --version` fails. Then run:

```sh
git clone https://github.com/tomtomjskim/lumarecall.git
cd lumarecall
make install
make app
open ".build/LumaRecall.app"
```

The menu bar sun icon opens the native brightness panel. The top button dims or restores the selected screens. Each editable row has a 10–100% slider. External sliders scale a fixed reference gamma curve, with the newly observed curve as 100% when no matching saved adjustment exists. Open the info button to set a display alias or include it in the work-end action. A disconnected display remains visible while its saved value is pending. Reconnect it and press restore. Its first use previews dimming for 10 seconds and restores automatically. To set a global hotkey, open the panel and choose **설정 (gear) → 단축키 → 단축키 기록 (pencil)**. A rejected binding keeps the previous one. In **설정 → 일반**, turn on **작업 종료 시 최저 밝기 (1%)** to save the setting immediately. The next work-end action targets 1%. The optional 3-second shortcut test is in **설정 → 단축키**.

Click **현재 밝기 저장** in the panel to save the current adjustable displays immediately with a name based on the saved displays and percentages. Use **프리셋 선택** to preview the saved percentage for each display and choose a preset, **관리** to edit its name or membership, and **ⓘ** beside 프리셋 for the in-app guide. Existing targets retain their saved brightness when edited. New targets use their current brightness. In **설정 → 단축키 → 프리셋 단축키**, use the pencil to register or change a shortcut and the × button to release it. Recording a chord and confirming Save replaces the previous binding only after macOS accepts the new one. Deleting a scene releases its binding. Applying a scene skips absent displays. The adjacent undo button restores the state immediately before the last scene application, keeping externally changed values. Work-end dimming has a separate restore record, so restoring after work-end returns to the active scene's brightness.

Double-click `display-brightness-toggle.command` in Finder or copy it to your Desktop. The launcher uses the default install path, `~/.local/bin/display-brightness-toggle`.

```sh
~/.local/bin/display-brightness-toggle          # Toggle dim / restore
~/.local/bin/display-brightness-toggle list     # List active displays
~/.local/bin/display-brightness-toggle dim
~/.local/bin/display-brightness-toggle restore
```

## How it works

- The built-in display uses Apple's DisplayServices backlight interface if available. DisplayServices is a private system interface and may change in future macOS versions.
- External displays use CoreGraphics gamma tables to dim the displayed image. This does not change the monitor's physical backlight or use DDC/CI. The tool needs a readable, writable gamma table for this mode.
- The initial target is 25%. The app offers 1% when a restore shortcut is registered and there are eligible displays. CLI dimming uses 25%. These percentages are backlight or gamma targets, not calibrated luminance.
- Original levels and gamma tables are stored by display UUID in `~/Library/Application Support/NativeDisplayBrightnessToggle/restore.json`. If a display is unplugged, reconnect it and run `restore` again. The app and CLI use the same per-user recovery file and lock.
- Changes to the display configuration or apps that also manage gamma may override software dimming.

Tested on Intel macOS 15.7.9 with the built-in display and two external monitors. Further macOS versions and GPU configurations have not been verified.

## License

[MIT](LICENSE)
