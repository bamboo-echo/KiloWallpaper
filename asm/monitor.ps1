# asm/monitor.ps1 - KiloWallpaper asm 版外部监控
# 由计划任务 KiloWallpaperMonitor 每 2 分钟调用一次。asm 版没有守护进程，
# 进程死了只能等下次登录才拉起——本脚本补上外部看护：
#   1) 进程存活：不在 → 立即重启
#   2) 日志心跳：debug.log 的 [res] 快照每 60s 一条，超 5 分钟无更新 = 消息循环卡死 → 重启
#   3) CPU 停滞：心跳正常但 CPU 增量 < 1s = 解码停滞 → 重启
#      （机器睡眠会导致 CPU/日志双停——用"上次检查时间"识别：间隔 >10 分钟则跳过 CPU 判定）
#   4) 新错误扫描：只扫上次检查之后新增的日志行，命中 failed 即记录
#   5) z 序回归：Progman 子窗口里 DefView 必须在壁纸窗口之上，否则图标会被盖 → 重启重锚
# 异常一律自愈并记 asm/monitor.log；状态（上次检查时间/CPU/日志行数）记 asm/monitor.state
# 手动跑一次：powershell -ExecutionPolicy Bypass -File asm\monitor.ps1

$ErrorActionPreference = "Continue"
$asmDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe        = Join-Path $asmDir "DynamicWallpaper.exe"
$logFile    = Join-Path $asmDir "debug.log"
$monLog     = Join-Path $asmDir "monitor.log"
$stateFile  = Join-Path $asmDir "monitor.state"

$HEARTBEAT_MAX_MIN = 5       # 日志心跳超时（分钟）
$CPU_RATE_MIN      = 0.01     # CPU 增量下限 = 间隔秒数 × 1%（健康解码约 3~4%，留 3 倍余量；
                              #   写死秒数会误杀——手动连跑时隔 21s 增量仅 0.7s 属正常）
$SLEEP_GAP_MIN      = 10      # 距上次检查超过该值视为睡眠/延迟，跳过 CPU 判定

function Write-Mon([string]$msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $monLog -Value "$ts [mon] $msg" -Encoding UTF8
}

function Get-WpProc {
    Get-Process -Name DynamicWallpaper -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$asmDir\*" }
}

function Start-Wp {
    # 经一次性计划任务启动：本环境验证过唯一能脱离调用方进程树/job 的方式
    # （WScript.Shell Run 的子进程会被调用方命令的沙箱/job 回收）
    $taskName = "KiloWallpaperRelaunch"
    $action = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $asmDir
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName | Out-Null
    } catch {
        Write-Mon "计划任务启动失败: $($_.Exception.Message)"
    }
}

function Restart-Wp($p, [string]$reason) {
    Write-Mon "$reason → 重启"
    if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Start-Wp
    Start-Sleep -Seconds 6
    $p2 = Get-WpProc
    if ($p2) {
        Write-Mon "重启成功 pid=$($p2.Id)"
    } else {
        Write-Mon "!! 重启失败，下次检查再试"
    }
    # 重置状态（新进程的 CPU/行数基准）
    Set-Content -Path $stateFile -Value @("$((Get-Date).Ticks)", "0", "0", "0")
}

# ---- 读状态：上次检查时间 / 上次 pid / 上次 CPU / 上次日志行数 ----
$lastTicks = 0; $lastPid = 0; $lastCpu = 0.0; $lastLines = 0
if (Test-Path $stateFile) {
    $s = @(Get-Content $stateFile -ErrorAction SilentlyContinue)
    if ($s.Count -ge 4) {
        $lastTicks = [int64]$s[0]
        $lastPid   = [int]$s[1]
        $lastCpu   = [double]$s[2]
        $lastLines = [int]$s[3]
    }
}
$nowTicks = (Get-Date).Ticks
$gapMin = 0
if ($lastTicks -gt 0) { $gapMin = ($nowTicks - $lastTicks) / 600000000.0 }

$proc = Get-WpProc

# ---- 1) 进程存活 ----
if (-not $proc) {
    Restart-Wp $null "壁纸进程不在"
    exit
}

# ---- 2) 日志心跳 ----
if (Test-Path $logFile) {
    $ageMin = ((Get-Date) - (Get-Item $logFile).LastWriteTime).TotalMinutes
    if ($ageMin -gt $HEARTBEAT_MAX_MIN) {
        Restart-Wp $proc ("日志 $([math]::Round($ageMin,1)) 分钟无更新（消息循环疑似卡死）")
        exit
    }
} else {
    Write-Mon "警告：debug.log 不存在（进程刚起或日志被删）"
}

# ---- 3) CPU 停滞（心跳正常但 CPU 不涨；睡眠间隔跳过；pid 变更重置基准） ----
$cpuNow = 0.0
try { $cpuNow = [double]$proc.CPU } catch { }
$cpuDelta = $cpuNow - $lastCpu
$cpuNeed = $gapMin * 60.0 * $CPU_RATE_MIN     # 阈值随间隔缩放
if ($lastPid -eq $proc.Id -and $lastCpu -gt 0 -and $gapMin -le $SLEEP_GAP_MIN -and $cpuDelta -lt $cpuNeed) {
    Restart-Wp $proc ("CPU 增量 $([math]::Round($cpuDelta,2))s < 阈值 $([math]::Round($cpuNeed,2))s（间隔 $([math]::Round($gapMin,1))min，解码疑似停滞）")
    exit
}

# ---- 4) 新错误扫描（只扫新增行） ----
if (Test-Path $logFile) {
    try {
        $all = @(Get-Content $logFile -Encoding Unicode -ErrorAction SilentlyContinue)
        $lineCount = $all.Count
        if ($lineCount -lt $lastLines) { $lastLines = 0 }   # 日志被重建
        if ($lineCount -gt $lastLines) {
            $newLines = $all[$lastLines..($lineCount - 1)]
            $errs = @($newLines | Where-Object { $_ -match "failed" })
            foreach ($e in $errs) { Write-Mon "日志错误: $($e.Trim())" }
            $lastLines = $lineCount
        }
    } catch {
        Write-Mon "日志扫描异常: $($_.Exception.Message)"
    }
}

# ---- 5) z 序回归检查 ----
try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class MonW {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc f, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumWindowsProc f, IntPtr l);
    public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
}
"@
    $script:progmanHwnd = [IntPtr]::Zero
    $cbTop = [MonW+EnumWindowsProc]{
        param($h, $l)
        $sb = New-Object System.Text.StringBuilder 256
        [void][MonW]::GetClassName($h, $sb, 256)
        if ($sb.ToString() -eq "Progman") { $script:progmanHwnd = $h; return $false }
        return $true
    }
    [void][MonW]::EnumWindows($cbTop, [IntPtr]::Zero)
    $zOrder = New-Object System.Collections.ArrayList
    if ($script:progmanHwnd -ne [IntPtr]::Zero) {
        $cbKids = [MonW+EnumWindowsProc]{
            param($h, $l)
            $sb = New-Object System.Text.StringBuilder 256
            [void][MonW]::GetClassName($h, $sb, 256)
            [void]$zOrder.Add($sb.ToString())
            return $true
        }
        [void][MonW]::EnumChildWindows($script:progmanHwnd, $cbKids, [IntPtr]::Zero)
    }
    $dvIdx = $zOrder.IndexOf("SHELLDLL_DefView")
    $wpIdx = $zOrder.IndexOf("DynamicWallpaper")
    if ($dvIdx -ge 0 -and $wpIdx -ge 0 -and $dvIdx -gt $wpIdx) {
        Restart-Wp $proc ("z 序回归：DefView(idx=$dvIdx) 落在壁纸(idx=$wpIdx) 之下，图标会被盖")
        exit
    }
} catch {
    Write-Mon "z 序检查异常: $($_.Exception.Message)"
}

# ---- 写状态 + OK 行 ----
Set-Content -Path $stateFile -Value @("$nowTicks", "$($proc.Id)", "$cpuNow", "$lastLines")
Write-Mon ("OK pid={0} cpu={1}s(+{2}) ws={3}MB 日志行={4} 距上次={5}min" -f `
    $proc.Id, [math]::Round($cpuNow, 1), [math]::Round($cpuDelta, 2), `
    [math]::Round($proc.WS / 1MB, 1), $lastLines, [math]::Round($gapMin, 1))
