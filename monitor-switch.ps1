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
    [switch]$Diag,     # registra também cada interface USB que entra/sai
    [switch]$Get,
    [Nullable[int]]$Set
)

# ---- Configuração ----------------------------------------------------------
# Switch USB Ugreen CM662 = 2 hubs Genesys (USB 2.0 e USB 3.0). Qualquer um presente = switch neste PC;
# o primeiro que chegar já troca a tela (o USB 3.0 costuma chegar segundos antes).
$DeviceIdPrefixes = @('USB\VID_05E3&PID_0610\', 'USB\VID_05E3&PID_0626\')
$InputDP        = 0x0F                        # DisplayPort
$InputHDMI      = 0x11                        # HDMI 1 (0x12 = HDMI 2)
$PollMs         = 250                         # checagem periódica (custa poucos ms); pega o hub antes do aviso
$LogFile        = Join-Path $PSScriptRoot 'monitor-switch.log'
# ---------------------------------------------------------------------------

if (-not ('Ddc' -as [type])) {
Add-Type @'
using System; using System.Text; using System.Threading;
using System.Collections.Generic; using System.Collections.Concurrent;
using System.Runtime.InteropServices;

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

// Detecção direta via Configuration Manager: o Windows chama o callback assim que
// uma interface de dispositivo chega/sai, sem passar pelo WMI.
public static class UsbWatch {
  [StructLayout(LayoutKind.Sequential, Size=416)]
  struct CM_NOTIFY_FILTER { public uint cbSize; public uint Flags; public int FilterType; public uint Reserved; }
  delegate uint NotifyCallback(IntPtr hNotify, IntPtr ctx, int action, IntPtr data, uint size);
  [DllImport("cfgmgr32.dll")] static extern uint CM_Register_Notification(ref CM_NOTIFY_FILTER f, IntPtr ctx, NotifyCallback cb, out IntPtr h);
  [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode)] static extern uint CM_Get_Device_ID_List_SizeW(out uint len, string filter, uint flags);
  [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode)] static extern uint CM_Get_Device_ID_ListW(string filter, char[] buf, uint len, uint flags);

  const uint FILTER_FLAG_ALL_INTERFACE_CLASSES = 1;
  const int  FILTER_TYPE_DEVICEINTERFACE = 0;
  const uint GETIDLIST_FILTER_ENUMERATOR = 0x1, GETIDLIST_FILTER_PRESENT = 0x100;

  public static readonly AutoResetEvent Signal = new AutoResetEvent(false);
  public static readonly ConcurrentQueue<string> DiagQueue = new ConcurrentQueue<string>();
  public static bool Diag;
  public static long FirstHit;    // timestamp do 1º evento do hub desde a última troca (medição)
  public static double MsSinceFirstHit() {
    long t = Interlocked.Exchange(ref FirstHit, 0);
    if (t == 0) return -1;
    return (System.Diagnostics.Stopwatch.GetTimestamp() - t) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
  }
  static string[] matches;        // ex.: "#VID_05E3&PID_0610#"
  static NotifyCallback keep;     // mantém o delegate vivo (GC)
  static IntPtr handle;

  public static void Start(string[] vidPids, bool diag) {
    Diag = diag;
    matches = Array.ConvertAll(vidPids, v => "#" + v.ToUpperInvariant() + "#");
    keep = OnNotify;
    var f = new CM_NOTIFY_FILTER();
    f.cbSize = 416; f.Flags = FILTER_FLAG_ALL_INTERFACE_CLASSES; f.FilterType = FILTER_TYPE_DEVICEINTERFACE;
    uint r = CM_Register_Notification(ref f, IntPtr.Zero, keep, out handle);
    if (r != 0) throw new Exception("CM_Register_Notification falhou: " + r);
  }

  static uint OnNotify(IntPtr h, IntPtr ctx, int action, IntPtr data, uint size) {
    // data: FilterType(4) Reserved(4) ClassGuid(16) SymbolicLink(WCHAR[])
    if (action != 0 && action != 1) return 0;   // 0 = chegada, 1 = remoção
    string link = Marshal.PtrToStringUni(IntPtr.Add(data, 24));
    if (link == null) return 0;
    string up = link.ToUpperInvariant(); bool hit = false;
    foreach (var m in matches) if (up.Contains(m)) hit = true;
    if (Diag) DiagQueue.Enqueue(DateTime.Now.ToString("HH:mm:ss.fff") + (action == 0 ? " + " : " - ") + link);
    if (hit) Interlocked.CompareExchange(ref FirstHit, System.Diagnostics.Stopwatch.GetTimestamp(), 0);
    if (hit || Diag) Signal.Set();
    return 0;
  }

  // Consulta rápida (milissegundos) se algum dispositivo com o prefixo está presente.
  public static bool IsPresent(string[] prefixes) {
    uint flags = GETIDLIST_FILTER_ENUMERATOR | GETIDLIST_FILTER_PRESENT;
    uint len;
    if (CM_Get_Device_ID_List_SizeW(out len, "USB", flags) != 0 || len == 0) return false;
    var buf = new char[len];
    if (CM_Get_Device_ID_ListW("USB", buf, len, flags) != 0) return false;
    foreach (var id in new string(buf).Split('\0')) {
      if (id.Length == 0) continue;
      string u = id.ToUpperInvariant();
      foreach (var p in prefixes) if (u.StartsWith(p.ToUpperInvariant())) return true;
    }
    return false;
  }
}
'@
}

function Write-Log($msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $msg
    Write-Host $line
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Remove-Item $LogFile -Force }
        Add-Content -Path $LogFile -Value $line -Encoding utf8
    } catch {}
}

function Switch-Input([int]$target) {
    for ($i = 1; $i -le 3; $i++) {
        if ([Ddc]::SetInput([uint32]$target)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    $false
}

if ($Get) { '0x{0:X2}' -f [Ddc]::GetInput(); return }
if ($null -ne $Set) { [Ddc]::SetInput([uint32]$Set); return }

# ---- Loop principal --------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\MonitorSwitchLogitech')
if (-not $mutex.WaitOne(0)) { Write-Log 'Já existe uma instância rodando; saindo.'; return }

$vidPids = [string[]]($DeviceIdPrefixes | ForEach-Object { ($_ -split '\\')[1] })   # VID_05E3&PID_0610, ...
[UsbWatch]::Start($vidPids, [bool]$Diag)
$last = [UsbWatch]::IsPresent($DeviceIdPrefixes)
Write-Log "Iniciado. Switch USB presente: $last"

try {
    while ($true) {
        [void][UsbWatch]::Signal.WaitOne($PollMs)
        $now = [UsbWatch]::IsPresent($DeviceIdPrefixes)

        # Na remoção o aviso pode chegar antes de o hub sair da lista: rechecagem curta.
        if ($now -eq $last -and [UsbWatch]::FirstHit -ne 0) {
            for ($i = 0; $i -lt 20 -and $now -eq $last; $i++) {
                Start-Sleep -Milliseconds 50
                $now = [UsbWatch]::IsPresent($DeviceIdPrefixes)
            }
            if ($now -eq $last) { [void][UsbWatch]::MsSinceFirstHit() }   # nada mudou: zera a medição
        }

        if ($now -ne $last) {
            # Age na hora. Se o botão oscilar, o próximo evento corrige o estado.
            $last = $now
            $target = if ($now) { $InputDP } else { $InputHDMI }
            $ok = if ($Switch) { Switch-Input $target } else { $null }
            $ms = [math]::Round([UsbWatch]::MsSinceFirstHit())
            $msg = if ($now) { 'Switch USB CONECTADO neste PC' } else { 'Switch USB DESCONECTADO (foi pro notebook)' }
            if ($Switch) {
                $name = if ($now) { 'DisplayPort' } else { 'HDMI' }
                $msg += if ($ok) { " -> $name (0x{0:X2})" -f $target } else { " -> FALHA ao trocar para $name" }
            }
            if ($ms -ge 0) { $msg += "  [$ms ms desde o evento]" }
            Write-Log $msg
        }

        if ($Diag) {
            $item = $null
            while ([UsbWatch]::DiagQueue.TryDequeue([ref]$item)) { Write-Log "   [diag] $item" }
        }
    }
} finally {
    $mutex.ReleaseMutex()
}
