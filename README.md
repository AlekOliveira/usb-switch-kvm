# usb-switch-kvm

Turns a **plain USB switch** (tested with the **Ugreen CM662**) into a **KVM**:
when you press the switch button, the **monitor changes input** along with your keyboard and mouse.

No KVM hardware, no monitor vendor software, no dependencies: a single PowerShell script using native Windows APIs.

## How it works

```
 [keyboard/mouse] ──► [Ugreen USB switch] ──┬──► Desktop (monitor DisplayPort)
                                            └──► Laptop  (monitor HDMI)
```

1. **Detection** – the script runs on the desktop and listens to Windows device events (`Win32_DeviceChangeEvent`, via WMI/CIM). On every event it checks whether the **switch's own USB hub** (`USB\VID_05E3&PID_0610`, Genesys Logic chip) is present.
   - It watches the **hub**, not the keyboard: plugging or unplugging peripherals does not change the screen, only the switch button does.
   - It only acts once the state has been stable for 1 s (ignores double presses / button bounce).
2. **Input switching** – uses **DDC/CI**, the VESA standard for controlling a monitor over the video cable, through the Windows *Monitor Configuration API* (`dxva2.dll`). VCP code `0x60` (Input Source) is set to:
   - `0x0F` → DisplayPort, when the switch is on the desktop
   - `0x11` → HDMI 1, when the switch goes to the laptop

## Requirements

- Windows 10/11 on the computer running the script
- A monitor with **DDC/CI** enabled in its menu (tested on a Samsung Odyssey G5)
- A USB switch that shows up as a hub in Windows
- **Turn off the monitor's automatic input switching** (e.g. *Auto Source Switch+* / *Source Detection* on Samsung). Otherwise, when the laptop wakes up (a mouse plugged directly into it is enough), the monitor jumps to HDMI on its own.

## Usage

```powershell
# only log switch connects/disconnects (does not touch the monitor)
.\monitor-switch.ps1

# KVM mode: change the monitor input together with the switch
.\monitor-switch.ps1 -Switch

# also log every USB device that comes and goes (diagnostics)
.\monitor-switch.ps1 -Switch -Diag

# utilities
.\monitor-switch.ps1 -Get         # show the monitor's current input
.\monitor-switch.ps1 -Set 0x11    # force an input
```

The log is written to `monitor-switch.log`, next to the script.

If PowerShell blocks the script, run it with `powershell -ExecutionPolicy Bypass -File .\monitor-switch.ps1 -Switch`.

## Start automatically at logon

Register a scheduled task that runs the script hidden every time you sign in (no admin needed). Run this from the folder that contains the script:

```powershell
$script = (Resolve-Path .\monitor-switch.ps1).Path
$user   = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
  -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`" -Switch"
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
  -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'USB Switch KVM' -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal
Start-ScheduledTask -TaskName 'USB Switch KVM'   # start it now, without signing out
```

The task points to the script's current path, so don't move the folder afterwards (or re-register the task).

To remove it:

```powershell
Stop-ScheduledTask 'USB Switch KVM'
Unregister-ScheduledTask 'USB Switch KVM' -Confirm:$false
```

## Adapting it to your setup

For now, configuration lives at the top of the script:

| Variable | Default | Meaning |
|---|---|---|
| `$DeviceIdPrefix` | `USB\VID_05E3&PID_0610\` | ID of the USB switch's hub |
| `$InputDP` | `0x0F` | monitor input when the switch is on this PC |
| `$InputHDMI` | `0x11` | monitor input when the switch leaves this PC |

To find your switch's ID, run with `-Diag`, press the button and see which hub appears and disappears in the log.
To find your monitor's input codes, run `-Get` on each input.

## Limitations

- The desktop can't tell where the switch went: unplugging the switch cable or cutting its power also sends the monitor to HDMI.

## Roadmap

- [ ] Command-line parameters / config file instead of variables in the script
- [x] Start automatically at logon (scheduled task)
- [ ] Built-in `-Install` / `-Uninstall` switches
- [ ] Wizard to discover the switch ID and monitor inputs
- [ ] Multi-monitor support

## License

MIT
