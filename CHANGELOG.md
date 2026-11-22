# Changelog

## 1.4.0 - 2026-11-21

- Night mode now also shows the black overlay, so a monitor that wakes at full brightness shows black instead of the desktop.
- Brightness fades back in over about 3 s when you return, instead of jumping straight to full.
- The self-test checks only Blackout by default. `-FullTest` adds Dim, Night and Power.

## 1.3.0 - 2026-11-21

- New default **Blackout** mode: a black click-through overlay plus brightness 0. Nothing flashes, the screen always comes back, and the overlay is hidden from screen capture so the agent can still see the desktop.
- The self-test measures whether screenshots can see through the overlay.
- Night mode is now opt-in (`-ScreenMode Night`).

## 1.2.1 - 2026-11-21

- Night mode: monitors that reset to full brightness when they wake are dimmed again about 1.2 s and 3.2 s after the agent wakes them.

## 1.2.0 - 2026-11-21

- New **Night** mode, now the default: screen off *and* dimmed, so agent wake-ups are dim. After agent input, the screen stays dimly on for `-AgentWindowSeconds` (60 s by default) so the agent can work, then goes black again.
- New `Start-DormantPC-Day.bat` for **Day** mode, which only dims the screen.
- Dimming happens before the screen turns off, and brightness is restored after it wakes, so monitors that ignore DDC/CI while off still restore correctly.
- The self-test now checks Night mode.

## 1.1.1 - 2026-11-21

- DDC/CI commands are now paced and retried, because some monitors drop commands sent back to back. This fixes brightness reads failing, which made Dim unavailable.
- The DDC power-off self-test is now opt-in (`-IncludeDdcTest`), because some monitors need their power button afterwards.

## 1.1.0 - 2026-11-21

- New default **Dim** mode: DDC/CI brightness and contrast set to 0. The monitor never powers off, so it always wakes, agent input can't light it, and screenshots keep working.
- DDC power-off mode is now opt-in (`-ScreenMode DDC`), because some monitors can't be woken over DDC/CI once off.
- Longer wake attempt for DDC mode: the video signal is cut for 6 s, then the script confirms the monitor reports "on".
- `Wake-DormantPC.bat` restores saved brightness and contrast after a crash.
- Self-test covers Dim, DDC and Power modes.

## 1.0.1 - 2026-11-21

- Fix: monitors that stop answering DDC/CI while off now wake reliably. If "on" isn't accepted, the video signal is cycled to bring the monitor out of standby.
- Self-test reports how the monitor was woken.

## 1.0.0 - 2026-11-21

- First release as **Dormant PC with AI**.
- DDC/CI screen-off that agent input can't wake; Windows monitor-off message as a fallback.
- Tells real input apart from injected (agent) input; only real input wakes the screen.
- RGB off/restore via OpenRGB.
- `Test-DormantPC.bat` self-test with log; `Wake-DormantPC.bat` rescue mode.
