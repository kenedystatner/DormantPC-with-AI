# Dormant PC with AI

Let an AI agent (Claude, or any tool that drives your PC) keep working overnight
while your PC sits **dark and quiet**: screen off, case/mouse/keyboard RGB off,
and the PC kept awake so the agent never loses its connection.

The key trick: **the agent's clicks and keystrokes don't wake the screen. Only
yours do.**

## Features

- **Stays awake.** Blocks Windows sleep while it runs, then restores your normal
  power settings when you stop it.
- **Blackout mode (default).** A black, click-through window covers the screen,
  and the monitor's brightness and contrast are set to 0 over DDC/CI. The screen
  is never powered off, so nothing flashes when the agent works and the monitor
  always comes back. The overlay is hidden from screen capture, so the agent's
  screenshots still show the desktop underneath. Needs Windows 10 version 2004
  or later.
- **Day mode.** The screen is only dimmed to brightness and contrast 0, and you
  can still faintly see the desktop.
- **Night mode** (`-ScreenMode Night`). The screen is powered off, dimmed, and
  covered by the black overlay. This is the darkest option. Agent input wakes the
  monitor, but it shows black instead of your desktop. The backlight may glow for
  a second until the script dims it again.
- **Gentle wake-up.** When you come back, brightness fades in over about 3 s
  instead of jumping straight to full.
- **Knows you from the agent.** Windows marks software-generated input as
  *injected*. Real mouse and keyboard input wakes the screen; injected input is
  ignored. The screen goes dark again after you've been idle for a set time
  (2 minutes by default).
- **RGB off.** Turns off case, mouse, keyboard, RAM and fan lighting through
  [OpenRGB](https://openrgb.org), then restores your saved profile.
- **Other screen modes.** `DDC` powers the monitor fully off over the cable.
  Not every monitor can be woken that way afterwards, so run the self-test
  first. `Power` uses Windows' monitor-off message and works on any monitor. The
  screen is re-blanked within about 0.2 s if the agent wakes it, but the agent's
  screenshots are black while the screen is off.
- **Self-test** that checks every part and writes a log.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in) or PowerShell 7
- *Recommended:* a monitor with **DDC/CI** turned on in its on-screen menu
  (most monitors have it)
- *Optional:* [OpenRGB](https://openrgb.org) for lighting control

## Install

1. Download or clone this repo:
   ```
   git clone https://github.com/kenedystatner/DormantPC-with-AI.git
   ```
   You can also use **Code → Download ZIP** and extract it.
2. *(For RGB)* Install OpenRGB. Set your lights the way you like them, then
   click **Save Profile** and name the profile `Normal`.
3. Double-click **`Test-DormantPC.bat`** and follow the prompts (see below).

## Usage

| Do this | To |
|---|---|
| Double-click `Start-DormantPC.bat` | **Blackout** mode: go dormant with the screen black (start this before you walk away) |
| Double-click `Start-DormantPC-Day.bat` | **Day** mode: the screen is only dimmed, never turned off |
| Double-click `Wake-DormantPC.bat` | End dormant mode: screen and RGB come back on, sleep returns to normal |
| Press **Enter** in the minimized "Dormant PC with AI" window | Same as Wake |
| Double-click `Test-DormantPC.bat` | Run diagnostics |

If you move your real mouse while dormant mode is running, the screen comes on for
you. Dormant mode itself keeps running until you use Wake.

### Options

Add options after the .bat file name, either in a shortcut or in a terminal, for example
`Start-DormantPC.bat -MaxHours 8 -ReblankAfterMinutes 5`.

| Option | Default | Meaning |
|---|---|---|
| `-ScreenMode Auto\|Blackout\|Dim\|Night\|Power\|DDC` | `Auto` (= Blackout) | See the features list above for what each mode does |
| `-AgentWindowSeconds N` | 60 (Night), 0.2 (Power) | How long the screen stays on after the agent's last input before going black again |
| `-ReblankAfterMinutes N` | `2` | Minutes after **your** last real input before the screen goes dark again |
| `-MaxHours N` | `0` (no limit) | Stop automatically after N hours |
| `-RestoreProfile Name` | `Normal` | OpenRGB profile to restore when you stop |
| `-OpenRGBPath path` | auto-detect | Location of `OpenRGB.exe` |
| `-DdcOffValue 4\|5` | `4` | Only used with `-ScreenMode DDC`. DDC/CI "off" value: 4 = standby-off, 5 = hard off |
| `-NoRgb` | off | Don't touch lighting |

## Self-test

`Test-DormantPC.bat` checks:

1. That the native code compiles and Windows accepts the stay-awake request
2. That the mouse and keyboard watcher installs
3. That simulated agent input is flagged as **agent**
4. That your real input is flagged as **you** (you'll be asked to move the mouse)
5. Which monitors support DDC/CI
6. Whether OpenRGB is installed and your restore profile exists
7. **Visual checks**: Blackout runs for about 20 s while simulated agent input is
   sent, and the test measures whether screenshots can still see through the
   overlay. The RGB lights also turn off and back on. Add `-FullTest` to check
   the Dim, Night and Power modes too.

The DDC power-off check is skipped unless you add `-IncludeDdcTest`, because some monitors need their power button to come back from it.

Results are saved in `DormantPC-selftest.log`. To skip the blackout checks, run
`Test-DormantPC.bat -SkipVisualTests`.

## Troubleshooting

- **The screen flickers or wakes when the agent works.** That monitor is in Power
  mode because DDC/CI isn't available. Turn on DDC/CI in the monitor's menu and
  run the test again. Some monitors only accept DDC/CI over DisplayPort or HDMI,
  not through docks or adapters.
- **Blackout isn't dark enough.** On LCDs the backlight still glows faintly
  through black pixels. Use `-ScreenMode Night` for a fully powered-off screen.
- **The agent's screenshots are black in Blackout mode.** Windows is older than
  10 version 2004 and can't hide the overlay from screen capture. Use Day mode.
- **In Night mode, the agent's first screenshot is black.** A screenshot doesn't
  wake the screen, but any mouse or keyboard input does. The agent can move the
  mouse first, and the screen then stays dimly on for `-AgentWindowSeconds`.
- **The monitor won't turn back on** (DDC mode). Press the monitor's power button
  once, then use Dim or Power mode instead. Many monitors stop listening to DDC/CI
  while they're off.
- **The screen stays dim after a crash.** Run `Wake-DormantPC.bat`. It restores the
  brightness and contrast that were saved when dormant mode started.
- **The RGB doesn't change, or comes back on.** Close the vendor lighting app
  (iCUE, G HUB, Synapse, Armoury Crate, and so on), or let OpenRGB control the
  device. Also make sure the device is listed in OpenRGB.
- **Antivirus warns about the script.** Low-level input hooks can look like a
  keylogger to antivirus software. This script only records *when* input
  happens and whether it was injected. It never reads which key was pressed.
  The source is all in `src/DormantPC.ps1`.
- **"The publisher could not be verified" each time you run a .bat file.**
  Windows marks files that came from a downloaded zip. Right-click the zip, choose
  **Properties**, tick **Unblock**, and extract it again. Alternatively, untick
  *Always ask before opening this file* the first time you click **Run**.
- **"Running scripts is disabled".** The .bat launchers use
  `-ExecutionPolicy Bypass` for this script only, so start the tool from the
  .bat files.

## How it works

| Piece | Windows API |
|---|---|
| Stay awake | `SetThreadExecutionState(ES_CONTINUOUS \| ES_SYSTEM_REQUIRED)` |
| Agent vs. you | `WH_MOUSE_LL` / `WH_KEYBOARD_LL` hooks, `LLMHF_INJECTED` / `LLKHF_INJECTED` flags |
| Blackout overlay | Click-through topmost window, `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` |
| Dim (DDC/CI) | `dxva2.dll` `SetVCPFeature`, VCP `0x10` brightness / `0x12` contrast |
| Screen off (DDC/CI) | `dxva2.dll` `SetVCPFeature`, VCP code `0xD6` (power mode) |
| Screen off (fallback) | `WM_SYSCOMMAND` / `SC_MONITORPOWER` |
| RGB | `OpenRGB.exe --mode static --color 000000`, then `--profile <name>` |

## License

MIT. See [LICENSE](LICENSE).
