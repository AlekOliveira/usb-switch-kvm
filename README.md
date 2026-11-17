# usb-switch-kvm

Turns a **plain USB switch** (tested with the **Ugreen CM662**) into a **KVM**:
when you press the switch button, the **monitor changes input** along with your keyboard and mouse.

No KVM hardware, no monitor vendor software, no dependencies: a single PowerShell script using native Windows APIs.

## How it works

```
 [keyboard/mouse] ──► [Ugreen USB switch] ──┬──► Desktop (monitor DisplayPort)
                                            └──► Laptop  (monitor HDMI)
```

1. **Detection** – the script runs on the desktop and registers for device-interface notifications straight from the Windows Configuration Manager (`CM_Register_Notification`), so it is called the moment a device arrives or leaves. It then checks (`CM_Get_Device_ID_List`, a few ms) whether the **switch's own USB hubs** are present. The CM662 shows up as two Genesys Logic hubs, USB 2.0 (`VID_05E3&PID_0610`) and USB 3.0 (`VID_05E3&PID_0626`); either one present means the switch is on this PC.
   - It watches the **hubs**, not the keyboard: plugging or unplugging peripherals does not change the screen, only the switch button does.
   - It acts immediately, with no debounce. If the button bounces, the next event corrects the state.
   - A 250 ms periodic check catches the hub as soon as Windows lists it, which can be seconds before its notification arrives.
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

The log is written to `monitor-switch.log`, next to the script, with millisecond timestamps. Each switch also records how long it took from the Windows notification to the monitor command.

### Performance

Measured on the author's setup:

- **Switch leaves the desktop:** about 70 ms from the Windows notification to the monitor command.
- **Switch comes back:** limited by how long Windows takes to enumerate the hub (about 1.5–4 s). The script reacts within 250 ms of the hub showing up.
- **Resource usage:** about 0.5% of one CPU core and about 85 MB of RAM, almost all of it the PowerShell runtime.

The monitor's own input-change time comes on top of these numbers.

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
| `$DeviceIdPrefixes` | `USB\VID_05E3&PID_0610\`, `USB\VID_05E3&PID_0626\` | IDs of the USB switch's hubs (any present = switch on this PC) |
| `$InputDP` | `0x0F` | monitor input when the switch is on this PC |
| `$InputHDMI` | `0x11` | monitor input when the switch leaves this PC |
| `$PollMs` | `250` | periodic presence check interval |

To find your switch's IDs, run with `-Diag`, press the button and see which hubs (`{f18a0e88-…}` interfaces) appear and disappear in the log.
To find your monitor's input codes, run `-Get` on each input.

## Limitations

- The desktop can't tell where the switch went: unplugging the switch cable or cutting its power also sends the monitor to HDMI.
- A very fast double press makes the screen flick to the other input and back, since the script reacts immediately.

## Roadmap

- [ ] Command-line parameters / config file instead of variables in the script
- [x] Start automatically at logon (scheduled task)
- [ ] Built-in `-Install` / `-Uninstall` switches
- [ ] Wizard to discover the switch ID and monitor inputs
- [ ] Multi-monitor support

## License

MIT
