# AstroOS on the ASUS Zenbook Duo (UX8406MA 2024, UX8406CA 2025)

Everything functional comes from upstream: the shipped kernels carry every Duo
fix for both models, KWin and PowerDevil drive both panels, touch, pen and
brightness, and the dock/undock, rotation, keyboard-backlight and hotkey
helper is zakstam/zenbook-duo-linux (GPL-3.0), packaged as astroos-zenbook-duo.
The package's services check the DMI product name and stay inert elsewhere.

## What works

- Both panels at their native mode (2880x1800 at 120 Hz on the 3K variant).
  Check: `kscreen-doctor --outputs`. Force: `kscreen-doctor output.eDP-1.mode.2880x1800@120 output.eDP-2.mode.2880x1800@120`.
- Dock the keyboard: bottom panel off. Undock: bottom panel on, Bluetooth on.
  Watch it: `journalctl -u zenbook-duo-rust-daemon -f`.
- Touch and pen on each panel. If a touch lands on the wrong panel:
  System Settings > Touchscreen > Target Display.
- Brightness for both panels from the Plasma applet and the keys (PowerDevil).
- Book mode: rotate the unit with the keyboard detached; the helper rotates
  both panels and re-positions the second one (KWin's own auto-rotate is off
  on a Duo on purpose).
- Keyboard over USB and Bluetooth, keyboard backlight (F4 cycles it),
  brightness keys (F5/F6), F7 display swap, F10 Bluetooth toggle.
- On-screen keyboard (Plasma Keyboard) when a text field is touched.
- Suspend and resume on lid close; Wi-Fi, Bluetooth, webcam, IR camera,
  speakers, microphones, Thunderbolt, VA-API, NPU.

## First boot on an installed system

astroos-zenbook-duo-setup disables Panel Self Refresh (PSR flickers on the
OLED panels) through /etc/modprobe.d/zenbook-duo-i915.conf and regenerates the
initramfs once; it takes effect at the next boot. Revert:
`sudo rm /etc/modprobe.d/zenbook-duo-i915.conf && sudo mkinitcpio -P`.

The system daemon needs the desktop user. zenbook-duo-env writes
/etc/zenbook-duo/env with the first regular account; edit it to choose another
user, delete it to re-detect.

## Known gaps (upstream status, 2026-09)

- No hardware tablet-mode switch: KWin only infers tablet mode when no
  pointer device is present (a Bluetooth-connected keyboard counts as one).
  Force it with `[Input] TabletMode=on|off|auto` in ~/.config/kwinrc.
- F8 (airplane) and F12 (MyASUS) do nothing; Fn lock is not implemented in the
  kernel; F9 mic mute works over USB only.
- No wake from sleep via the Bluetooth keyboard; keyboard battery level on
  Linux unverified (`upower -d` after pairing).
- 3.5 mm microphone input does not work; audio occasionally garbles.
- Inking with the touch layer inhibited is a manual toggle
  (`echo 1 | sudo tee /sys/bus/i2c/devices/*/inhibited` on the bottom panel's
  touch node keeps the pen alive).
- ICC profiles: extract from MyASUS on Windows and set them per output in
  System Settings > Display; not shipped (redistribution rights unverified).
- The 2026 model (UX8407AA) is not supported yet: its bottom panel needs an
  out-of-tree i915 patch.

## Pairing the keyboard over Bluetooth

Hold F10 until the LED blinks, then pair it in the Bluetooth applet
(`bluetoothctl` also works).

Sources: .planning/R4_ZENBOOK_DUO.md in the AstroOS repository (48 references).
