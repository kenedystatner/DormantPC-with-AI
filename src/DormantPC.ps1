<#
.SYNOPSIS
  Dormant PC with AI - keep your PC awake for an AI agent while the screen and
  RGB lights stay dark. Only YOUR real mouse/keyboard wakes the screen.

.DESCRIPTION
  While running:
    1. Blocks sleep so the AI agent (Claude, etc.) can keep working.
    2. Turns RGB lighting off (case, mouse, keyboard, RAM, fans) via OpenRGB.
    3. Turns the monitor(s) off:
       - DDC/CI mode: sends "power off" to the monitor over the video cable.
         Windows still thinks the screen is on, so the agent's clicks and
         keystrokes can't wake it, and the agent can still take screenshots.
       - Power mode (fallback for monitors without DDC/CI): uses Windows'
         monitor-off message and instantly re-blanks if the agent wakes it.
    4. Watches input. Windows flags software-generated input as "injected".
       Injected input (the agent) is ignored; real input (you) wakes the screen.
       After you stop touching the PC for -ReblankAfterMinutes, it goes dark.

  Only the TIME of input and whether it was real or injected is recorded.
  Which keys you press is never read or stored.

.EXAMPLE
  .\DormantPC.ps1                       # start (normally via Start-DormantPC.bat)
  .\DormantPC.ps1 -MaxHours 8           # auto-stop after 8 hours
  .\DormantPC.ps1 -ScreenMode Power     # force the fallback screen method
  .\DormantPC.ps1 -SelfTest             # run diagnostics (Test-DormantPC.bat)
  .\DormantPC.ps1 -WakeOnly             # rescue: force screens + lights back on
#>

[CmdletBinding()]
param(
    # Auto = Blackout. Blackout = black click-through overlay + brightness 0 (no
    # flashes; agent screenshots see through it). Dim = brightness 0 only.
    # Night = screen powered off + dimmed. Power = screen powered off. DDC = DDC power off.
    [ValidateSet('Auto', 'Blackout', 'Dim', 'Night', 'Power', 'DDC')]
    [string]$ScreenMode = 'Auto',

    # Minutes after YOUR last real input before the screen goes dark again
    [ValidateRange(1, 1440)]
    [int]$ReblankAfterMinutes = 2,

    # OpenRGB profile restored when you stop. Create it once in OpenRGB:
    # set your lights how you like -> Save Profile -> "Normal"
    [string]$RestoreProfile = 'Normal',

    # Night/Power: after the agent wakes the screen, keep it on this long after the
    # agent's last input so it can see what it's doing (-1 = 60 s Night, 0.2 s Power)
    [double]$AgentWindowSeconds = -1,

    # Stop automatically after this many hours (0 = run until stopped)
    [double]$MaxHours = 0,

    # Full path to OpenRGB.exe if it isn't in a standard location
    [string]$OpenRGBPath = '',

    # DDC/CI power value for "off": 4 = DPM off (default, safest), 5 = hard off
    [ValidateRange(2, 5)]
    [int]$DdcOffValue = 4,

    # Don't touch RGB lighting at all
    [switch]$NoRgb,

    # Run diagnostics instead of starting
    [switch]$SelfTest,

    # With -SelfTest: skip the tests that turn the screen/lights off
    [switch]$SkipVisualTests,

    # With -SelfTest: also run the Dim, Night and Power visual tests
    [switch]$FullTest,

    # With -SelfTest: also test DDC power-off (some monitors then need their power button)
    [switch]$IncludeDdcTest,

    # Force all screens and lights back on, then exit
    [switch]$WakeOnly
)

$ErrorActionPreference = 'Stop'
$Version  = '1.4.0'
$AppName  = 'Dormant PC with AI'
$RootDir  = Split-Path -Parent $PSScriptRoot
$StopFile = Join-Path $env:TEMP 'DormantPC.stop'
$PidFile  = Join-Path $env:TEMP 'DormantPC.pid'
$DimFile  = Join-Path $env:TEMP 'DormantPC.dim'
$LogFile  = if ($SelfTest) { Join-Path $RootDir 'DormantPC-selftest.log' } else { Join-Path $RootDir 'DormantPC.log' }
if ($SelfTest) { Remove-Item $LogFile -ErrorAction SilentlyContinue }

function Clear-KeyBuffer {
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
}

function Get-WakeText([int]$Code) {
    switch ($Code) {
        0 { 'no DDC/CI monitors - display nudged on' }
        1 { 'DDC/CI "on" accepted' }
        2 { 'monitor ignored DDC/CI while off - woke it by cycling the video signal' }
        default { 'sent DDC/CI "on" and cycled the signal for 6 s, but the monitor never reported being on' }
    }
}

function Write-Log([string]$Message, [string]$Color = 'Gray') {
    Write-Host $Message -ForegroundColor $Color
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -Path $LogFile -Value $line } catch { }
}

# ---------------------------------------------------------------------------
# Native code (C# 5 so it compiles on stock Windows PowerShell 5.1)
# ---------------------------------------------------------------------------
if (-not ('DormantNative' -as [type])) {
Add-Type -IgnoreWarnings -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Drawing;
using System.Windows.Forms;

// Full-screen black window: click-through, never takes focus, and (Windows 10
// 2004+) excluded from screen capture, so the agent's screenshots see the
// desktop underneath while the person sees black.
public class BlackOverlay : Form {
    [DllImport("user32.dll")]
    static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")]
    static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);

    public bool CaptureExcluded;

    public BlackOverlay() {
        FormBorderStyle = FormBorderStyle.None;
        BackColor = Color.Black;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Bounds = SystemInformation.VirtualScreen;
        TopMost = true;
    }

    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            // LAYERED | TRANSPARENT (click-through) | TOOLWINDOW | NOACTIVATE | TOPMOST
            cp.ExStyle |= 0x80000 | 0x20 | 0x80 | 0x08000000 | 0x8;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        SetLayeredWindowAttributes(Handle, 0, 255, 0x2);          // LWA_ALPHA, fully opaque
        CaptureExcluded = SetWindowDisplayAffinity(Handle, 0x11);  // WDA_EXCLUDEFROMCAPTURE
    }
}

public static class DormantNative {
    // ---------- basics ----------
    [DllImport("user32.dll")]
    static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint flags);
    [DllImport("user32.dll")]
    static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")]
    static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);

    static long Now() { return DateTime.UtcNow.Ticks / 10000; }

    // ---------- input hooks ----------
    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int idHook, HookProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")]
    static extern bool PostThreadMessage(uint threadId, uint msg, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")]
    static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    static extern IntPtr GetModuleHandle(string name);

    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr w; public IntPtr l; public uint time; public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)]
    struct MSLLHOOKSTRUCT { public int x; public int y; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint vk; public uint scan; public uint flags; public uint time; public IntPtr extra; }

    const int WH_KEYBOARD_LL = 13, WH_MOUSE_LL = 14;
    const uint LLMHF_INJECTED = 0x01, LLMHF_LOWER_IL_INJECTED = 0x02;
    const uint LLKHF_INJECTED = 0x10, LLKHF_LOWER_IL_INJECTED = 0x02;

    static HookProc mouseProc = MouseHook;   // fields keep delegates alive
    static HookProc keyProc = KeyHook;
    static IntPtr mouseHook, keyHook;
    static uint hookThreadId;

    static long lastPhysical, lastInjected, lastBlank;
    public static long PhysicalCount, InjectedCount;

    static void Record(bool injected) {
        if (injected) { Interlocked.Exchange(ref lastInjected, Now()); Interlocked.Increment(ref InjectedCount); }
        else { Interlocked.Exchange(ref lastPhysical, Now()); Interlocked.Increment(ref PhysicalCount); }
    }

    static IntPtr MouseHook(int n, IntPtr w, IntPtr l) {
        if (n >= 0) {
            MSLLHOOKSTRUCT info = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(MSLLHOOKSTRUCT));
            Record((info.flags & (LLMHF_INJECTED | LLMHF_LOWER_IL_INJECTED)) != 0);
        }
        return CallNextHookEx(IntPtr.Zero, n, w, l);
    }

    static IntPtr KeyHook(int n, IntPtr w, IntPtr l) {
        if (n >= 0) {
            KBDLLHOOKSTRUCT info = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(KBDLLHOOKSTRUCT));
            Record((info.flags & (LLKHF_INJECTED | LLKHF_LOWER_IL_INJECTED)) != 0);
        }
        return CallNextHookEx(IntPtr.Zero, n, w, l);
    }

    public static bool StartHooks() {
        if (hookThreadId != 0) return HooksOk();
        lastPhysical = Now(); lastInjected = 0; lastBlank = Now();
        ManualResetEvent ready = new ManualResetEvent(false);
        Thread t = new Thread(delegate() {
            hookThreadId = GetCurrentThreadId();
            IntPtr mod = GetModuleHandle(Process.GetCurrentProcess().MainModule.ModuleName);
            mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, mod, 0);
            keyHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyProc, mod, 0);
            ready.Set();
            MSG msg;
            while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) { }
            if (mouseHook != IntPtr.Zero) UnhookWindowsHookEx(mouseHook);
            if (keyHook != IntPtr.Zero) UnhookWindowsHookEx(keyHook);
            mouseHook = IntPtr.Zero; keyHook = IntPtr.Zero;
        });
        t.IsBackground = true;
        t.Start();
        ready.WaitOne(5000);
        return HooksOk();
    }

    public static bool HooksOk() { return mouseHook != IntPtr.Zero && keyHook != IntPtr.Zero; }

    // Treat the user as "away" from now on (called after the start double-click)
    public static void MarkAway() { Interlocked.Exchange(ref lastPhysical, Now() - presenceMs); }

    // ---------- monitors / DDC-CI ----------
    delegate bool MonitorEnumProc(IntPtr hMon, IntPtr hdc, IntPtr rect, IntPtr data);
    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PHYSICAL_MONITOR {
        public IntPtr handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string desc;
    }
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMon, out uint count);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMon, uint count, [Out] PHYSICAL_MONITOR[] arr);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr type, out uint cur, out uint max);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool DestroyPhysicalMonitor(IntPtr h);

    const byte VCP_POWER = 0xD6, VCP_BRIGHTNESS = 0x10, VCP_CONTRAST = 0x12;

    public class DisplayInfo {
        public string Name; public IntPtr Handle; public bool Ddc;
        public bool CanDim; public uint Brightness; public uint Contrast;
    }
    static List<DisplayInfo> monitors = new List<DisplayInfo>();
    public static int DdcOffValue = 4;

    // DDC/CI is slow and monitors drop commands sent too close together:
    // pace every command and retry reads.
    static bool ReadVcp(IntPtr h, byte code, out uint cur, out uint max) {
        cur = 0; max = 0;
        for (int i = 0; i < 6; i++) {
            if (GetVCPFeatureAndVCPFeatureReply(h, code, IntPtr.Zero, out cur, out max)) { Thread.Sleep(60); return true; }
            Thread.Sleep(150);
        }
        return false;
    }

    static bool WriteVcp(IntPtr h, byte code, uint value) {
        for (int i = 0; i < 5; i++) {
            if (SetVCPFeature(h, code, value)) { Thread.Sleep(60); return true; }
            Thread.Sleep(200);
        }
        return false;
    }

    public static DisplayInfo[] OpenMonitors() {
        CloseMonitors();
        List<IntPtr> hmons = new List<IntPtr>();
        MonitorEnumProc cb = delegate(IntPtr h, IntPtr dc, IntPtr rc, IntPtr d) { hmons.Add(h); return true; };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        GC.KeepAlive(cb);
        foreach (IntPtr hm in hmons) {
            uint n;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out n) || n == 0) {
                DisplayInfo u = new DisplayInfo(); u.Name = "Display (no DDC/CI info)"; u.Handle = IntPtr.Zero; u.Ddc = false;
                monitors.Add(u); continue;
            }
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hm, n, arr)) {
                DisplayInfo u = new DisplayInfo(); u.Name = "Display (no DDC/CI info)"; u.Handle = IntPtr.Zero; u.Ddc = false;
                monitors.Add(u); continue;
            }
            foreach (PHYSICAL_MONITOR pm in arr) {
                uint cur, max;
                bool ok = ReadVcp(pm.handle, VCP_POWER, out cur, out max);
                DisplayInfo m = new DisplayInfo();
                m.Name = String.IsNullOrEmpty(pm.desc) ? "Display" : pm.desc;
                m.Handle = pm.handle; m.Ddc = ok;
                uint b, bmax, c, cmax;
                bool okB = ReadVcp(pm.handle, VCP_BRIGHTNESS, out b, out bmax);
                bool okC = ReadVcp(pm.handle, VCP_CONTRAST, out c, out cmax);
                m.CanDim = okB && okC && !(b == 0 && c == 0);
                m.Brightness = b; m.Contrast = c;
                monitors.Add(m);
            }
        }
        return monitors.ToArray();
    }

    public static void CloseMonitors() {
        foreach (DisplayInfo m in monitors) if (m.Handle != IntPtr.Zero) DestroyPhysicalMonitor(m.Handle);
        monitors.Clear();
    }

    public static int DdcPower(bool on) {
        int okCount = 0;
        foreach (DisplayInfo m in monitors) {
            if (!m.Ddc) continue;
            if (WriteVcp(m.Handle, VCP_POWER, on ? 1u : (uint)DdcOffValue)) okCount++;
        }
        return okCount;
    }

    public static int DdcMonitorCount() {
        int n = 0;
        foreach (DisplayInfo m in monitors) if (m.Ddc) n++;
        return n;
    }

    // Brings DDC/CI-off monitors back. Many monitors stop answering DDC/CI
    // while they're off, so if "on" isn't accepted we cycle the video signal
    // (Windows monitor-off, then on), which wakes a monitor from standby.
    // Returns: 0 = nothing to wake, 1 = DDC "on" accepted,
    //          2 = woke via signal cycle (DDC confirmed after),
    //          3 = signal cycle sent but DDC still not answering.
    // True only if every DDC/CI monitor answers and reports power mode 1 (on)
    public static bool DdcAllOn() {
        foreach (DisplayInfo m in monitors) {
            if (!m.Ddc) continue;
            uint cur, max;
            if (!ReadVcp(m.Handle, VCP_POWER, out cur, out max)) return false;
            if (cur != 1) return false;
        }
        return true;
    }

    public static int WakeScreens() {
        int want = DdcMonitorCount();
        if (want == 0) { DisplayOn(); return 0; }
        DdcPower(true);
        Thread.Sleep(1500);
        if (DdcAllOn()) return 1;
        // Monitor isn't listening: drop the video signal long enough for the
        // monitor to notice, then bring it back and keep asking for ~10 s.
        PowerMessageOff();
        Thread.Sleep(6000);
        DisplayOn();
        for (int i = 0; i < 10; i++) {
            Thread.Sleep(1000);
            DdcPower(true);
            if (DdcAllOn()) return 2;
        }
        return 3;
    }

    // ---------- Dim mode: brightness + contrast to 0, monitor stays on ----------
    public static int DimCount() {
        int n = 0;
        foreach (DisplayInfo m in monitors) if (m.CanDim) n++;
        return n;
    }

    public static int FadeInMs = 3000;

    public static int Dim(bool dark) {
        int ok = 0;
        foreach (DisplayInfo m in monitors) {
            if (!m.CanDim) continue;
            bool a, b;
            if (dark) {
                a = WriteVcp(m.Handle, VCP_BRIGHTNESS, 0);
                b = WriteVcp(m.Handle, VCP_CONTRAST, 0);
            } else {
                // Fade in: contrast first (invisible at brightness 0), then
                // raise brightness in steps so a dark room isn't hit all at once.
                b = WriteVcp(m.Handle, VCP_CONTRAST, m.Contrast);
                int steps = Math.Max(1, FadeInMs / 300);
                a = true;
                for (int i = 1; i <= steps; i++) {
                    uint level = (uint)(m.Brightness * i / steps);
                    a = WriteVcp(m.Handle, VCP_BRIGHTNESS, level) && a;
                    if (i < steps) Thread.Sleep(Math.Max(0, FadeInMs / steps - 60));
                }
                if (!a) a = WriteVcp(m.Handle, VCP_BRIGHTNESS, m.Brightness);
            }
            if (a && b) ok++;
        }
        return ok;
    }

    // "b,c;b,c" - saved so a crash can't leave the monitor at 0 brightness
    public static string SavedLevels() {
        List<string> parts = new List<string>();
        foreach (DisplayInfo m in monitors) parts.Add(m.CanDim ? (m.Brightness + "," + m.Contrast) : "-");
        return String.Join(";", parts.ToArray());
    }

    public static int RestoreLevels(string saved) {
        string[] parts = saved.Trim().Split(';');
        int ok = 0;
        for (int i = 0; i < parts.Length && i < monitors.Count; i++) {
            string[] bc = parts[i].Split(',');
            if (bc.Length != 2) continue;
            uint b, c;
            if (!UInt32.TryParse(bc[0], out b) || !UInt32.TryParse(bc[1], out c)) continue;
            if (b == 0 && c == 0) continue;
            DisplayInfo m = monitors[i];
            m.Brightness = b; m.Contrast = c; m.CanDim = true;
            if (WriteVcp(m.Handle, VCP_BRIGHTNESS, b) & WriteVcp(m.Handle, VCP_CONTRAST, c)) ok++;
        }
        return ok;
    }

    public static void PowerMessageOff() {
        // HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2 = off
        PostMessage((IntPtr)0xFFFF, 0x0112, (IntPtr)0xF170, (IntPtr)2);
    }

    public static void DisplayOn() {
        SetThreadExecutionState(0x00000002); // ES_DISPLAY_REQUIRED (one-shot)
        mouse_event(0x0001, 1, 0, 0, UIntPtr.Zero);
        mouse_event(0x0001, -1, 0, 0, UIntPtr.Zero);
    }

    // Simulates agent input: a harmless F15 key + a 1px mouse wiggle
    public static void SendInjectedInput() {
        keybd_event(0x7E, 0, 0, UIntPtr.Zero);
        keybd_event(0x7E, 0, 2, UIntPtr.Zero);
        mouse_event(0x0001, 1, 0, 0, UIntPtr.Zero);
        mouse_event(0x0001, -1, 0, 0, UIntPtr.Zero);
    }

    // ---------- black overlay ----------
    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    static BlackOverlay overlay;
    static volatile bool overlayShown;

    static void EnsureOverlay() {
        if (overlay != null) return;
        ManualResetEvent ready = new ManualResetEvent(false);
        Thread t = new Thread(delegate() {
            overlay = new BlackOverlay();
            IntPtr h = overlay.Handle; // force handle creation on this thread
            ready.Set();
            Application.Run();
        });
        t.SetApartmentState(ApartmentState.STA);
        t.IsBackground = true;
        t.Start();
        ready.WaitOne(5000);
    }

    public static bool OverlayCaptureExcluded() { EnsureOverlay(); return overlay != null && overlay.CaptureExcluded; }

    public static void ShowOverlay() {
        EnsureOverlay();
        if (overlay == null) return;
        overlay.Invoke((MethodInvoker)delegate {
            overlay.Bounds = SystemInformation.VirtualScreen;
            overlay.Show();
            overlay.TopMost = true;
        });
        overlayShown = true;
        KeepOverlayOnTop();
    }

    public static void HideOverlay() {
        if (overlay == null) return;
        overlay.Invoke((MethodInvoker)delegate { overlay.Hide(); });
        overlayShown = false;
    }

    public static void KeepOverlayOnTop() {
        if (overlay == null || !overlayShown) return;
        // HWND_TOPMOST, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
        SetWindowPos(overlay.Handle, (IntPtr)(-1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10);
    }

    public static void StopOverlay() {
        if (overlay == null) return;
        try { overlay.Invoke((MethodInvoker)delegate { overlay.Hide(); Application.ExitThread(); }); } catch { }
        overlay = null; overlayShown = false;
    }

    // Average brightness (0-255) of the screen as a screenshot would see it
    public static double CaptureBrightness() {
        Rectangle r = SystemInformation.VirtualScreen;
        using (Bitmap bmp = new Bitmap(r.Width, r.Height)) {
            using (Graphics g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.Left, r.Top, 0, 0, r.Size);
            double sum = 0; int n = 0;
            for (int y = 5; y < r.Height; y += Math.Max(1, r.Height / 40))
                for (int x = 5; x < r.Width; x += Math.Max(1, r.Width / 60)) {
                    Color c = bmp.GetPixel(x, y);
                    sum += 0.299 * c.R + 0.587 * c.G + 0.114 * c.B; n++;
                }
            return n == 0 ? 0 : sum / n;
        }
    }

    // ---------- guard: decides when the screen is on/off ----------
    static System.Threading.Timer timer;
    static bool useDdc, usePower, useDim, useOverlay;
    static long lastTopmost;
    static volatile bool dimmed;
    static long agentWindowMs = 200;
    // Night mode: many monitors reset to full brightness when they wake from
    // standby, so after the agent wakes the screen we re-apply Dim twice.
    static long wakeSeenAt;      // first agent input after the last blank
    static int redimStep;        // 0 = none yet, 1 = first re-dim done, 2 = both done
    public static int RedimDelayMs = 1200;
    static volatile bool screenOff;
    static int busy;
    static long presenceMs = 120000;

    public static void StartGuard(bool ddc, bool power, bool dim, bool overlayOn, int presenceMinutes, int agentWindowMs_) {
        useDdc = ddc; usePower = power; useDim = dim; useOverlay = overlayOn;
        if (useOverlay) EnsureOverlay();
        agentWindowMs = Math.Max(200, agentWindowMs_);
        presenceMs = (long)presenceMinutes * 60 * 1000;
        timer = new System.Threading.Timer(Tick, null, 250, 250);
    }

    static void ScreenOff() {
        // Dim while the monitor is still on - many monitors ignore DDC/CI while off
        if (useOverlay) ShowOverlay();
        if (useDim && !dimmed) { Dim(true); dimmed = true; if (usePower) Thread.Sleep(300); }
        if (useDdc) DdcPower(false);
        if (usePower) PowerMessageOff();
        screenOff = true;
        wakeSeenAt = 0; redimStep = 0;
        Interlocked.Exchange(ref lastBlank, Now());
    }

    static void ScreenOn() {
        if (useOverlay) HideOverlay();
        if (useDdc) WakeScreens();
        if (useDim && dimmed) {
            if (usePower) Thread.Sleep(1500); // let the monitor finish waking first
            Dim(false); dimmed = false;
        }
        screenOff = false;
    }

    static void Tick(object state) {
        if (Interlocked.Exchange(ref busy, 1) == 1) return;
        try {
            long t = Now();
            long phys = Interlocked.Read(ref lastPhysical);
            long inj = Interlocked.Read(ref lastInjected);
            long blank = Interlocked.Read(ref lastBlank);
            bool present = (t - phys) < presenceMs;

            if (screenOff && phys > blank) { ScreenOn(); return; }      // you came back
            if (present) return;                                        // you're using it
            if (useOverlay && screenOff && t - lastTopmost > 2000) { KeepOverlayOnTop(); lastTopmost = t; }
            if (!screenOff) { ScreenOff(); return; }                    // you left

            // Night: agent woke the screen -> re-dim once the monitor is listening
            if (usePower && useDim && inj > blank) {
                if (wakeSeenAt == 0) wakeSeenAt = inj;
                if (redimStep == 0 && t - wakeSeenAt >= RedimDelayMs) { Dim(true); redimStep = 1; }
                else if (redimStep == 1 && t - wakeSeenAt >= RedimDelayMs + 2000) { Dim(true); redimStep = 2; }
            }
            // agent woke it (Power/Night): let it work for agentWindowMs, then blank again
            if (usePower && inj > blank && (t - inj) > agentWindowMs) ScreenOff();
        } catch { }
        finally { Interlocked.Exchange(ref busy, 0); }
    }

    public static bool IsScreenOff() { return screenOff; }

    public static void StopAll() {
        if (timer != null) { timer.Dispose(); timer = null; }
        Thread.Sleep(300);
        StopOverlay();
        if (useDdc) WakeScreens(); else if (screenOff) DisplayOn();
        if (useDim && dimmed) {
            if (usePower) Thread.Sleep(2000);
            Dim(false); dimmed = false;
        }
        screenOff = false;
        if (hookThreadId != 0) { PostThreadMessage(hookThreadId, 0x0012, IntPtr.Zero, IntPtr.Zero); hookThreadId = 0; }
        CloseMonitors();
    }
}
"@
}

$ES_CONTINUOUS      = [uint32]'0x80000000'
$ES_SYSTEM_REQUIRED = [uint32]'0x00000001'
[DormantNative]::DdcOffValue = $DdcOffValue

# ---------------------------------------------------------------------------
# RGB via OpenRGB
# ---------------------------------------------------------------------------
function Find-OpenRGB {
    if ($OpenRGBPath) { if (Test-Path $OpenRGBPath) { return $OpenRGBPath } else { return $null } }
    $candidates = @(
        "$env:ProgramFiles\OpenRGB\OpenRGB.exe",
        "${env:ProgramFiles(x86)}\OpenRGB\OpenRGB.exe",
        "$env:LOCALAPPDATA\Programs\OpenRGB\OpenRGB.exe",
        "$env:USERPROFILE\OpenRGB\OpenRGB.exe",
        "$env:USERPROFILE\Downloads\OpenRGB\OpenRGB.exe",
        'C:\OpenRGB\OpenRGB.exe'
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command OpenRGB.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-OpenRGB([string[]]$OrgArgs) {
    if (-not $script:OpenRGB) { return $false }
    try {
        $p = Start-Process -FilePath $script:OpenRGB -ArgumentList $OrgArgs -WindowStyle Hidden -PassThru
        if (-not $p.WaitForExit(30000)) {
            try { $p.Kill() } catch { }
            Write-Log '  OpenRGB took too long and was stopped.' Yellow
            return $false
        }
        if ($p.ExitCode -ne 0) { Write-Log "  OpenRGB exited with code $($p.ExitCode)" Yellow; return $false }
        return $true
    } catch {
        Write-Log "  Couldn't run OpenRGB: $($_.Exception.Message)" Yellow
        return $false
    }
}

function Set-RgbOff {
    if ($NoRgb -or -not $script:OpenRGB) { return $false }
    Write-Log 'Turning RGB off...'
    return (Invoke-OpenRGB @('--mode', 'static', '--color', '000000'))
}

function Restore-Rgb {
    if ($NoRgb -or -not $script:OpenRGB -or -not $RestoreProfile) { return $false }
    Write-Log "Restoring RGB profile '$RestoreProfile'..."
    return (Invoke-OpenRGB @('--profile', "`"$RestoreProfile`""))
}

function Test-RgbProfile {
    $dirs = @("$env:APPDATA\OpenRGB")
    if ($script:OpenRGB) { $dirs += (Split-Path $script:OpenRGB -Parent) }
    foreach ($d in $dirs) {
        if (Test-Path (Join-Path $d "$RestoreProfile.orp")) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Screen mode
# ---------------------------------------------------------------------------
function Resolve-ScreenMode {
    $mons = [DormantNative]::OpenMonitors()
    $total = @($mons).Count
    $ddcN = @($mons | Where-Object { $_.Ddc }).Count
    $dimN = @($mons | Where-Object { $_.CanDim }).Count
    foreach ($m in $mons) {
        $tags = @()
        if ($m.Ddc) { $tags += 'power control' }
        if ($m.CanDim) { $tags += 'brightness control' }
        if (-not $tags) { $tags = @('no DDC/CI') }
        Write-Log ("  Monitor: {0} [{1}]" -f $m.Name, ($tags -join ', '))
    }
    $r = @{ Ddc = $false; Power = $false; Dim = $false; Overlay = $false }
    $mode = $ScreenMode
    if ($mode -eq 'Auto') { $mode = 'Blackout' }
    switch ($mode) {
        'Blackout' {
            $r.Overlay = $true
            if ($dimN -gt 0) {
                $r.Dim = $true
                Set-Content -Path $DimFile -Value ([DormantNative]::SavedLevels())
            } else { Write-Log 'No monitor allows brightness control - black overlay only (backlight stays at its normal level).' Yellow }
            if (-not [DormantNative]::OverlayCaptureExcluded()) {
                Write-Log 'Warning: this Windows version cannot hide the overlay from screenshots - the agent will see black.' Yellow
            }
        }
        'DDC' {
            if ($ddcN -eq 0) { Write-Log 'No monitor answered DDC/CI power control - using Power mode.' Yellow; $r.Power = $true }
            else { $r.Ddc = $true }
        }
        { $_ -in 'Dim', 'Night' } {
            if ($dimN -eq 0) { Write-Log 'No monitor allows brightness control - using Power mode.' Yellow; $r.Power = $true }
            else {
                $r.Dim = $true
                if ($mode -eq 'Night') { $r.Power = $true; $r.Overlay = $true }
                Set-Content -Path $DimFile -Value ([DormantNative]::SavedLevels())
            }
        }
        default { $r.Power = $true }
    }
    $desc = if ($r.Overlay -and $r.Power) { 'Night - screen off, dimmed, black overlay (agent wake-ups show black, not your desktop)' }
            elseif ($r.Overlay) { 'Blackout - black overlay' + $(if ($r.Dim) { ' + brightness 0' } else { '' }) + ' (no flashes; agent screenshots see through it)' }
            elseif ($r.Ddc) { 'DDC/CI power off (agent input cannot wake it)' }
            elseif ($r.Dim) { 'Dim - brightness/contrast 0 (agent input cannot brighten it, screenshots work)' }
            else { 'Power (agent input may flash the screen; screenshots are black while off)' }
    Write-Log ('Screen method: ' + $desc)
    return $r
}

# ---------------------------------------------------------------------------
# Wake-only (rescue)
# ---------------------------------------------------------------------------
if ($WakeOnly) {
    Write-Log "$AppName - waking screens and lights"
    $script:OpenRGB = Find-OpenRGB
    [void][DormantNative]::OpenMonitors()
    [DormantNative]::DisplayOn()
    Start-Sleep -Seconds 2
    if (Test-Path $DimFile) {
        $n = [DormantNative]::RestoreLevels((Get-Content $DimFile -Raw))
        Write-Log "  Restored brightness/contrast on $n monitor(s)."
        Remove-Item $DimFile -ErrorAction SilentlyContinue
    }
    $w = [DormantNative]::WakeScreens()
    [DormantNative]::CloseMonitors()
    Write-Log ("  Wake result: " + (Get-WakeText $w))
    [void](Restore-Rgb)
    Write-Log 'Done. If a monitor is still dark, press its power button once.'
    exit 0
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
if ($SelfTest) {
    $results = [ordered]@{}
    function Set-Result($name, $status, $detail) {
        $results[$name] = "$status - $detail"
        $color = switch ($status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Cyan' } }
        Write-Log ("[{0}] {1}: {2}" -f $status, $name, $detail) $color
    }

    Write-Log "=== $AppName v$Version - self-test ===" Cyan
    Write-Log ("Windows {0} | PowerShell {1} | {2}" -f [Environment]::OSVersion.Version, $PSVersionTable.PSVersion, $env:COMPUTERNAME)
    Set-Result 'Native code' 'PASS' 'compiled and loaded'

    # Stay-awake
    [void][DormantNative]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
    $prev = [DormantNative]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
    if (($prev -band $ES_SYSTEM_REQUIRED) -ne 0) { Set-Result 'Stay awake' 'PASS' 'sleep block accepted by Windows' }
    else { Set-Result 'Stay awake' 'FAIL' 'SetThreadExecutionState returned 0' }
    [void][DormantNative]::SetThreadExecutionState($ES_CONTINUOUS)

    # Hooks
    if ([DormantNative]::StartHooks()) { Set-Result 'Input watcher' 'PASS' 'mouse + keyboard hooks installed' }
    else { Set-Result 'Input watcher' 'FAIL' 'could not install hooks (antivirus or policy?)' }

    # Injected input is recognised as the agent
    Start-Sleep -Milliseconds 300
    $i0 = [DormantNative]::InjectedCount; $p0 = [DormantNative]::PhysicalCount
    [DormantNative]::SendInjectedInput()
    Start-Sleep -Milliseconds 600
    $di = [DormantNative]::InjectedCount - $i0; $dp = [DormantNative]::PhysicalCount - $p0
    if ($di -ge 2 -and $dp -eq 0) { Set-Result 'Agent input detection' 'PASS' "$di simulated events flagged as agent, 0 as you" }
    elseif ($di -ge 2) { Set-Result 'Agent input detection' 'WARN' "$di flagged as agent, but $dp as you (did you touch the mouse?)" }
    else { Set-Result 'Agent input detection' 'FAIL' "only $di of 4 simulated events were seen" }

    # Real input is recognised as you
    Clear-KeyBuffer
    Write-Log ''
    Write-Log '>>> Move YOUR mouse or press a key on YOUR keyboard within 20 seconds...' Cyan
    $p1 = [DormantNative]::PhysicalCount; $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and [DormantNative]::PhysicalCount -eq $p1) { Start-Sleep -Milliseconds 200 }
    if ([DormantNative]::PhysicalCount -gt $p1) { Set-Result 'Your input detection' 'PASS' 'real mouse/keyboard recognised as you' }
    else { Set-Result 'Your input detection' 'SKIP' 'no real input in 20 s' }
    Clear-KeyBuffer

    # Monitors
    Write-Log ''
    $mons = [DormantNative]::OpenMonitors()
    $total = @($mons).Count; $ddcN = @($mons | Where-Object { $_.Ddc }).Count
    $dimN = @($mons | Where-Object { $_.CanDim }).Count
    foreach ($m in $mons) {
        Write-Log ("  Monitor: {0} [power control: {1}, brightness control: {2} (now {3}/{4})]" -f $m.Name, $m.Ddc, $m.CanDim, $m.Brightness, $m.Contrast)
    }
    if ($dimN -gt 0) { Set-Result 'Dim support' 'PASS' "$dimN of $total monitor(s) allow brightness/contrast control" }
    else { Set-Result 'Dim support' 'WARN' 'no monitor allows brightness control - Dim mode unavailable' }
    if ($total -eq 0) { Set-Result 'Monitors' 'WARN' 'no monitors enumerated' }
    elseif ($ddcN -eq $total) { Set-Result 'Monitors / DDC-CI' 'PASS' "$ddcN of $total monitor(s) support DDC/CI power control" }
    elseif ($ddcN -gt 0) { Set-Result 'Monitors / DDC-CI' 'WARN' "$ddcN of $total support DDC/CI; others use Power mode" }
    else { Set-Result 'Monitors / DDC-CI' 'WARN' "none of $total support DDC/CI (enable DDC/CI in the monitor's menu?) - Power mode will be used" }

    # OpenRGB
    $script:OpenRGB = Find-OpenRGB
    if ($NoRgb) { Set-Result 'OpenRGB' 'SKIP' '-NoRgb given' }
    elseif ($script:OpenRGB) {
        Set-Result 'OpenRGB' 'PASS' "found at $($script:OpenRGB)"
        if (Test-RgbProfile) { Set-Result 'RGB restore profile' 'PASS' "'$RestoreProfile' profile found" }
        else { Set-Result 'RGB restore profile' 'WARN' "no '$RestoreProfile.orp' found - lights can't be restored exactly. Save one in OpenRGB." }
    } else { Set-Result 'OpenRGB' 'WARN' 'not installed - RGB will be skipped (get it at openrgb.org)' }

    if (-not $SkipVisualTests) {
        Write-Log ''
        Write-Log ''
        Write-Log '>>> VISUAL TEST 0 (Blackout): in 5 s a black overlay covers the screen and brightness' Cyan
        Write-Log '    goes to 0 for ~20 s. Simulated agent input is sent - nothing should flash.' Cyan
        Write-Log '    The test also checks that screenshots can still see through the overlay.' Cyan
        Write-Log '    At the end brightness FADES back in over ~3 s.' Cyan
        Start-Sleep -Seconds 5
        $base = [DormantNative]::CaptureBrightness()
        $excl = [DormantNative]::OverlayCaptureExcluded()
        if ($dimN -gt 0) { Set-Content -Path $DimFile -Value ([DormantNative]::SavedLevels()); [void][DormantNative]::Dim($true) }
        [DormantNative]::ShowOverlay()
        Start-Sleep -Seconds 2
        $seen = [DormantNative]::CaptureBrightness()
        for ($k = 0; $k -lt 4; $k++) { Start-Sleep -Seconds 4; [DormantNative]::SendInjectedInput(); [DormantNative]::KeepOverlayOnTop() }
        [DormantNative]::HideOverlay()
        if ($dimN -gt 0) { [void][DormantNative]::Dim($false); Remove-Item $DimFile -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        $seeThrough = ($seen -gt 3) -or ($base -le 3)
        $detail = ("capture-exclusion API: {0}; screenshot brightness before {1:N0}, during {2:N0}" -f $excl, $base, $seen)
        if ($seeThrough) { Set-Result 'Blackout: agent can see through' 'PASS' $detail }
        else { Set-Result 'Blackout: agent can see through' 'FAIL' "$detail - screenshots would be black" }
        Set-Result 'Visual test 0 (Blackout)' 'CHECK' 'How dark was it, and did anything flash?'

        if (-not $FullTest) { Set-Result 'Other screen modes' 'SKIP' 'add -FullTest to also test Dim, Night and Power' }
        if ($FullTest -and $dimN -gt 0) {
            Set-Content -Path $DimFile -Value ([DormantNative]::SavedLevels())
            Write-Log ''
            Write-Log '>>> VISUAL TEST 1 (Dim): brightness + contrast go to 0 for ~10 s while simulated' Cyan
            Write-Log '    agent input is sent. Note how dark it gets. It comes back by itself.' Cyan
            Start-Sleep -Seconds 4
            $d = [DormantNative]::Dim($true)
            for ($k = 0; $k -lt 3; $k++) { Start-Sleep -Seconds 3; [DormantNative]::SendInjectedInput() }
            Start-Sleep -Seconds 1
            $u = [DormantNative]::Dim($false)
            Remove-Item $DimFile -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Set-Result 'Visual test 1 (Dim)' 'CHECK' "dim accepted by $d, restore accepted by $u. How dark was it - dark enough?"
        }
        if ($ddcN -gt 0 -and -not $IncludeDdcTest) {
            Set-Result 'Visual test 2 (DDC/CI off)' 'SKIP' 'opt-in (add -IncludeDdcTest); some monitors need their power button afterwards'
        }
        if ($ddcN -gt 0 -and $IncludeDdcTest) {
            Write-Log '>>> VISUAL TEST 2 (DDC/CI off + longer wake): screen powers off for ~10 s, then the' Cyan
            Write-Log '    script tries to wake it (can take up to ~25 s). If it is not back after 40 s,' Cyan
            Write-Log '    press the monitor power button.' Cyan
            Start-Sleep -Seconds 4
            $off = [DormantNative]::DdcPower($false)
            for ($k = 0; $k -lt 3; $k++) { Start-Sleep -Seconds 3; [DormantNative]::SendInjectedInput() }
            Start-Sleep -Seconds 1
            $w = [DormantNative]::WakeScreens()
            Start-Sleep -Seconds 2
            $wt = Get-WakeText $w
            if ($off -lt 1) { Set-Result 'Visual test 2 (DDC/CI off)' 'FAIL' 'monitor refused the DDC/CI off command' }
            elseif ($w -eq 1 -or $w -eq 2) { Set-Result 'Visual test 2 (DDC/CI off)' 'PASS' "wake: $wt" }
            else { Set-Result 'Visual test 2 (DDC/CI off)' 'WARN' "wake: $wt. Did it come back by itself?" }
        }
        Write-Log ''
        if ($FullTest -and $dimN -gt 0) {
            Set-Content -Path $DimFile -Value ([DormantNative]::SavedLevels())
            Write-Log ''
            Write-Log '>>> VISUAL TEST 3 (Night): in 5 s the screen dims and turns fully off. Simulated agent' Cyan
            Write-Log '    input then wakes it: it should show BLACK (backlight may glow ~1-2 s), then go dark again.' Cyan
            Write-Log '    At the end brightness FADES back in over ~3 s (~30 s total).' Cyan
            Start-Sleep -Seconds 5
            [DormantNative]::ShowOverlay()
            $d = [DormantNative]::Dim($true)
            Start-Sleep -Milliseconds 500
            [DormantNative]::PowerMessageOff()
            for ($k = 0; $k -lt 2; $k++) {
                Start-Sleep -Seconds 4
                [DormantNative]::SendInjectedInput()
                Start-Sleep -Milliseconds ([DormantNative]::RedimDelayMs)
                [void][DormantNative]::Dim($true)
                Start-Sleep -Seconds 2
                [void][DormantNative]::Dim($true)
                Start-Sleep -Seconds 3
                [DormantNative]::PowerMessageOff()
            }
            Start-Sleep -Seconds 3
            [DormantNative]::DisplayOn()
            Start-Sleep -Seconds 2
            [DormantNative]::HideOverlay()
            $u = [DormantNative]::Dim($false)
            Remove-Item $DimFile -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Set-Result 'Visual test 3 (Night)' 'CHECK' "dim ok=$d, restore ok=$u. Did wake-ups show black (not your desktop), and did brightness fade back in?"
        } elseif ($FullTest) {
            Write-Log '>>> VISUAL TEST 3 (Power): in 5 s the screen goes fully off for ~8 s. Simulated agent' Cyan
            Write-Log '    input wakes it twice and the script re-blanks it. A quick flash is normal.' Cyan
            Start-Sleep -Seconds 5
            [DormantNative]::PowerMessageOff()
            for ($k = 0; $k -lt 2; $k++) {
                Start-Sleep -Seconds 3
                [DormantNative]::SendInjectedInput(); Start-Sleep -Milliseconds 200; [DormantNative]::PowerMessageOff()
            }
            Start-Sleep -Seconds 2
            [DormantNative]::DisplayOn()
            Start-Sleep -Seconds 2
            Set-Result 'Visual test 3 (Power)' 'CHECK' 'Did the screen mostly stay dark (a brief flash is normal) and come back?'
        }

        if ($script:OpenRGB -and -not $NoRgb) {
            Write-Log '>>> VISUAL TEST 4 (RGB): lights go off for ~5 s, then your profile is restored.' Cyan
            $a = Set-RgbOff; Start-Sleep -Seconds 5; $b = Restore-Rgb
            Set-Result 'Visual test 4 (RGB)' 'CHECK' "off command ok=$a, restore ok=$b. Did case/mouse lights go off and come back?"
        }
    } else { Set-Result 'Visual tests' 'SKIP' '-SkipVisualTests given' }

    [DormantNative]::StopAll()
    Write-Log ''
    Write-Log '=== Summary ===' Cyan
    foreach ($k in $results.Keys) { Write-Log ("  {0}: {1}" -f $k, $results[$k]) }
    Write-Log "Log saved to $LogFile"
    exit 0
}

# ---------------------------------------------------------------------------
# Normal run
# ---------------------------------------------------------------------------
if (Test-Path $PidFile) {
    $old = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($old -and $old -ne "$PID") {
        $proc = Get-Process -Id $old -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match 'powershell|pwsh') {
            Write-Log "$AppName is already running (PID $old). Use Wake-DormantPC.bat to stop it." Yellow
            Start-Sleep -Seconds 4
            exit 1
        }
    }
}
Remove-Item $StopFile -ErrorAction SilentlyContinue
Set-Content -Path $PidFile -Value $PID

$started = Get-Date
try {
    Write-Log "=== $AppName v$Version - starting ===" Cyan
    [void][DormantNative]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)

    $mode = Resolve-ScreenMode

    $script:OpenRGB = Find-OpenRGB
    if (-not $NoRgb -and -not $script:OpenRGB) {
        Write-Log 'OpenRGB not found - skipping RGB (get it at openrgb.org or pass -OpenRGBPath).' Yellow
    }
    [void](Set-RgbOff)

    if (-not [DormantNative]::StartHooks()) {
        Write-Log "Warning: couldn't watch mouse/keyboard - the screen won't come back on by itself. Use Wake-DormantPC.bat." Yellow
    }
    $win = $AgentWindowSeconds
    if ($win -lt 0) { $win = if ($mode.Dim) { 60 } else { 0.2 } }
    if ($mode.Power) { Write-Log ("After agent activity the screen stays on (dimmed in Night mode) for {0} s." -f $win) }
    [DormantNative]::StartGuard($mode.Ddc, $mode.Power, $mode.Dim, $mode.Overlay, $ReblankAfterMinutes, [int]($win * 1000))

    Write-Log ''
    Write-Log 'DORMANT MODE IS ON. The PC stays awake; screen goes dark in 2 seconds.' Green
    Write-Log "Your real mouse/keyboard wakes the screen; it goes dark again after $ReblankAfterMinutes min of no use."
    Write-Log 'To end: double-click Wake-DormantPC.bat, or press Enter in this window.'
    Start-Sleep -Seconds 2
    [DormantNative]::MarkAway()

    while ($true) {
        Start-Sleep -Seconds 2
        [void][DormantNative]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)

        if (Test-Path $StopFile) { Write-Log 'Stop requested.'; break }
        try {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Enter') { Write-Log 'Enter pressed.'; break }
            }
        } catch { }

        if ($MaxHours -gt 0 -and ((Get-Date) - $started).TotalHours -ge $MaxHours) {
            Write-Log "Reached the $MaxHours hour limit."; break
        }
    }
}
catch {
    Write-Log "Error: $($_.Exception.Message)" Red
}
finally {
    [DormantNative]::StopAll()
    [void](Restore-Rgb)
    [void][DormantNative]::SetThreadExecutionState($ES_CONTINUOUS)
    Remove-Item $StopFile, $PidFile, $DimFile -ErrorAction SilentlyContinue
    Write-Log 'Screens and lights back on. Normal sleep settings restored.' Green
    Start-Sleep -Seconds 2
}
