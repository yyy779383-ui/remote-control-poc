#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\..\build\poc\device-info.json')
)

$ErrorActionPreference = 'Stop'

function Invoke-AdbRead {
    param([string]$Path, [string[]]$Arguments)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw '无法启动 adb。' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill($true)
            throw 'adb 超过 15 秒未响应。'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'adb 读取失败。' }
        return $output.Trim()
    } finally {
        $process.Dispose()
    }
}

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property Caption, Version, BuildNumber, OSArchitecture
    $memory = Get-CimInstance -ClassName Win32_ComputerSystem -Property TotalPhysicalMemory
    $report = [ordered]@{
        schemaVersion = 1
        windows = [ordered]@{
            os = [ordered]@{
                name = $os.Caption
                version = $os.Version
                build = $os.BuildNumber
                architecture = $os.OSArchitecture
            }
            ramGiB = [math]::Round($memory.TotalPhysicalMemory / 1GB, 2)
            cpu = @(
                Get-CimInstance -ClassName Win32_Processor -Property Name, NumberOfCores, NumberOfLogicalProcessors |
                    ForEach-Object { [ordered]@{
                        name = $_.Name
                        cores = $_.NumberOfCores
                        logicalProcessors = $_.NumberOfLogicalProcessors
                    } }
            )
            gpu = @(
                Get-CimInstance -ClassName Win32_VideoController -Property Name, DriverVersion |
                    ForEach-Object { [ordered]@{ name = $_.Name; driverVersion = $_.DriverVersion } }
            )
        }
        android = [ordered]@{
            status = 'adb_not_found'
            unauthorizedCount = 0
            otherUnavailableCount = 0
            devices = @()
        }
    }

    $adbCommand = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $adbPath = if ($adbCommand) { $adbCommand.Source } else { $null }
    $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
    if ($env:LOCALAPPDATA) { $sdkRoots += Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    if (-not $adbPath) {
        foreach ($sdkRoot in $sdkRoots) {
            if ($sdkRoot -and (Test-Path -LiteralPath (Join-Path $sdkRoot 'platform-tools\adb.exe'))) {
                $adbPath = Join-Path $sdkRoot 'platform-tools\adb.exe'
                break
            }
        }
    }
    if ($adbPath) {
        try {
            $deviceOutput = Invoke-AdbRead -Path $adbPath -Arguments @('devices')
            $report.android.status = 'no_authorized_device'
            foreach ($line in ($deviceOutput -split '\r?\n')) {
                if ($line -notmatch '^([^\s]+)\s+(device|unauthorized|offline|recovery|sideload|bootloader)\b') { continue }
                $deviceId = $Matches[1]
                $deviceState = $Matches[2]
                if ($deviceState -eq 'unauthorized') {
                    $report.android.unauthorizedCount++
                    continue
                }
                if ($deviceState -ne 'device') {
                    $report.android.otherUnavailableCount++
                    continue
                }
                try {
                    $phone = [ordered]@{}
                    foreach ($property in @(
                        @('brand', 'ro.product.brand'),
                        @('manufacturer', 'ro.product.manufacturer'),
                        @('model', 'ro.product.model'),
                        @('androidVersion', 'ro.build.version.release'),
                        @('androidApiLevel', 'ro.build.version.sdk')
                    )) {
                        $phone[$property[0]] = Invoke-AdbRead -Path $adbPath -Arguments @('-s', $deviceId, 'shell', 'getprop', $property[1])
                    }
                    $report.android.devices += $phone
                } catch {
                    $report.android.otherUnavailableCount++
                    Write-Warning '一台手机未能完成只读信息收集，请检查连接后重试。'
                }
            }
            if ($report.android.devices.Count -gt 0) { $report.android.status = 'collected' }
        } catch {
            $report.android.status = 'adb_unavailable'
            Write-Warning 'adb 暂时无法读取，已继续收集本机 Windows 信息。'
        }
    }

    $outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path $outputFullPath -Parent
    $null = New-Item -ItemType Directory -Path $outputDirectory -Force
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputFullPath -Encoding utf8
    Write-Host "设备报告已保存到：$outputFullPath"
    Write-Host '只包含硬件和系统版本，未记录账号、设备序列号、IP、Android ID 或屏幕内容，未上传。'
    if ($report.android.devices.Count -eq 0) {
        Write-Host '本次没有读取到已授权手机；Windows 报告已生成。连接手机并在手机上允许 USB 调试后，可重新运行。'
    } else {
        Write-Host ("已收集 {0} 台授权 Android 设备的品牌、型号和系统版本。" -f $report.android.devices.Count)
    }
    exit 0
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
