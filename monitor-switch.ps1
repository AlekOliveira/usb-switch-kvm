# Troca o input do monitor (Odyssey G5) conforme o switch USB Ugreen CM662
# aparece/some neste PC.
#   switch neste PC   -> DisplayPort
#   switch no notebook -> HDMI
#
# Uso:
#   .\monitor-switch.ps1              # só monitora e registra conexões/desconexões
#   .\monitor-switch.ps1 -Switch      # monitora E troca o input do monitor
#   .\monitor-switch.ps1 -Get         # mostra o input atual
#   .\monitor-switch.ps1 -Set 0x11    # força um input

param(
    [switch]$Switch,   # sem isso, só monitora e registra (não troca o input)
    [switch]$Diag,     # registra também cada dispositivo USB que entra/sai
    [switch]$Get,
    [Nullable[int]]$Set
)

# ---- Configuração ----------------------------------------------------------
$DeviceIdPrefix = 'USB\VID_05E3&PID_0610\'   # switch USB Ugreen CM662 (hub Genesys, parte USB 2.0)
$InputDP        = 0x0F                        # DisplayPort
$InputHDMI      = 0x11                        # HDMI 1 (0x12 = HDMI 2)
$PollSeconds    = 2                           # fallback, caso algum evento se perca
$LogFile        = Join-Path $PSScriptRoot 'monitor-switch.log'
# ---------------------------------------------------------------------------

if (-not ('Ddc' -as [type])) {
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class Ddc {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct PHYSICAL_MONITOR { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string d; }
  delegate bool EnumProc(IntPtr hMon, IntPtr hdc, IntPtr r, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, EnumProc cb, IntPtr p);
  [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
  [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] a);
  [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr t, out uint cur, out uint max);
  [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte code, uint v);
  [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, PHYSICAL_MONITOR[] a);

  static void ForEach(Func<IntPtr,bool> fn) {
    var hs = new List<IntPtr>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (h,a,b,c) => { hs.Add(h); return true; }, IntPtr.Zero);
    foreach (var hm in hs) {
      uint n; if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out n) || n == 0) continue;
      var arr = new PHYSICAL_MONITOR[n];
      if (!GetPhysicalMonitorsFromHMONITOR(hm, n, arr)) continue;
      try { foreach (var p in arr) fn(p.h); } finally { DestroyPhysicalMonitors(n, arr); }
    }
  }
  public static int GetInput() {
    int r = -1;
    ForEach(h => { uint c, m; if (GetVCPFeatureAndVCPFeatureReply(h, 0x60, IntPtr.Zero, out c, out m)) r = (int)c; return true; });
    return r;
  }
  public static bool SetInput(uint v) {
    bool ok = false;
    ForEach(h => { if (SetVCPFeature(h, 0x60, v)) ok = true; return true; });
    return ok;
  }
}
'@
}

function Write-Log($msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    Write-Host $line
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Remove-Item $LogFile -Force }
        Add-Content -Path $LogFile -Value $line -Encoding utf8
    } catch {}
}

function Test-Receiver {
    $f = "DeviceID LIKE '" + ($DeviceIdPrefix -replace '\\', '\\') + "%'"
    [bool](Get-CimInstance Win32_PnPEntity -Filter $f -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-UsbSnapshot {
    $h = @{}
    Get-CimInstance Win32_PnPEntity -Filter "DeviceID LIKE 'USB\\%'" -ErrorAction SilentlyContinue |
        ForEach-Object { $h[$_.DeviceID] = $_.Name }
    $h
}

function Write-UsbDiff($old, $new) {
    foreach ($k in $new.Keys) { if (-not $old.ContainsKey($k)) { Write-Log "   [diag] + $($new[$k])  ($k)" } }
    foreach ($k in $old.Keys) { if (-not $new.ContainsKey($k)) { Write-Log "   [diag] - $($old[$k])  ($k)" } }
}

function Switch-Input([int]$target, [string]$name) {
    for ($i = 1; $i -le 3; $i++) {
        if ([Ddc]::SetInput([uint32]$target)) { Write-Log "-> $name (0x$('{0:X2}' -f $target))"; return }
        Start-Sleep -Milliseconds 500
    }
    Write-Log "FALHA ao trocar para $name"
}

if ($Get) { '0x{0:X2}' -f [Ddc]::GetInput(); return }
if ($null -ne $Set) { [Ddc]::SetInput([uint32]$Set); return }

# ---- Loop principal --------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\MonitorSwitchLogitech')
if (-not $mutex.WaitOne(0)) { Write-Log 'Já existe uma instância rodando; saindo.'; return }

Register-CimIndicationEvent -ClassName Win32_DeviceChangeEvent -SourceIdentifier DevChange | Out-Null
$last = Test-Receiver
if ($Diag) { $snap = Get-UsbSnapshot }
Write-Log "Iniciado. Switch USB presente: $last"

try {
    while ($true) {
        $ev = Wait-Event -SourceIdentifier DevChange -Timeout $PollSeconds
        if ($ev) {
            # agrupa a rajada de eventos que o Windows gera numa conexão USB
            Start-Sleep -Milliseconds 300
            Get-Event -SourceIdentifier DevChange -ErrorAction SilentlyContinue | Remove-Event
            if ($Diag) {
                $snapNow = Get-UsbSnapshot
                Write-Log '[diag] evento USB recebido'
                Write-UsbDiff $snap $snapNow
                $snap = $snapNow
            }
        }
        $now = Test-Receiver
        if ($now -ne $last) {
            # só age se o estado ficar estável por 1 s (evita clique duplo / botão oscilando)
            Start-Sleep -Seconds 1
            if ((Test-Receiver) -ne $now) { Write-Log '   estado instável, aguardando...'; continue }
            $last = $now
            Write-Log ($(if ($now) { 'Switch USB CONECTADO neste PC' } else { 'Switch USB DESCONECTADO (foi pro notebook)' }))
            if (-not $Switch) { continue }
            if ($now) { Switch-Input $InputDP 'DisplayPort' } else { Switch-Input $InputHDMI 'HDMI' }
        }
    }
} finally {
    Unregister-Event -SourceIdentifier DevChange -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
}
