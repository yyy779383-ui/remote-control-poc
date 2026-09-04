[CmdletBinding()]
param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param(
        [string]$Name,
        [ValidateSet('ok', 'warning', 'blocked')]
        [string]$Status,
        [string]$Detail
    )

    $checks.Add([pscustomobject]@{
        name = $Name
        status = $Status
        detail = $Detail
    })
}

function Get-FirstLine {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    $resolved = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $resolved) {
        return $null
    }

    $output = & $resolved.Source @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return [string]($output | Select-Object -First 1)
}

$gitVersion = Get-FirstLine -Command 'git' -Arguments @('--version')
if ($gitVersion) {
    Add-Check -Name 'Git' -Status 'ok' -Detail $gitVersion
} else {
    Add-Check -Name 'Git' -Status 'blocked' -Detail 'git is not available'
}

$rustVersion = Get-FirstLine -Command 'rustc' -Arguments @('--version')
if (-not $rustVersion) {
    Add-Check -Name 'Rust' -Status 'blocked' -Detail 'rustc is not available; CI baseline is 1.75'
} elseif ($rustVersion -match '^rustc 1\.75\.') {
    Add-Check -Name 'Rust' -Status 'ok' -Detail $rustVersion
} else {
    Add-Check -Name 'Rust' -Status 'warning' -Detail "$rustVersion; CI baseline is 1.75"
}

$flutterVersion = Get-FirstLine -Command 'flutter' -Arguments @('--version')
if (-not $flutterVersion) {
    Add-Check -Name 'Flutter' -Status 'blocked' -Detail 'flutter is not available; build baseline is 3.24.5'
} elseif ($flutterVersion -match 'Flutter 3\.24\.5') {
    Add-Check -Name 'Flutter' -Status 'ok' -Detail $flutterVersion
} else {
    Add-Check -Name 'Flutter' -Status 'warning' -Detail "$flutterVersion; Windows x64 and Android baseline is 3.24.5"
}

foreach ($tool in @('cmake', 'ninja', 'python', 'adb')) {
    $resolved = Get-Command $tool -ErrorAction SilentlyContinue
    if ($resolved) {
        Add-Check -Name $tool -Status 'ok' -Detail $resolved.Source
    } else {
        Add-Check -Name $tool -Status 'blocked' -Detail "$tool is not available"
    }
}

$clangVersion = Get-FirstLine -Command 'clang' -Arguments @('--version')
if (-not $clangVersion) {
    Add-Check -Name 'LLVM/Clang' -Status 'blocked' -Detail 'clang is not available; CI baseline is LLVM 15.0.6'
} elseif ($clangVersion -match 'version 15\.0\.6') {
    Add-Check -Name 'LLVM/Clang' -Status 'ok' -Detail $clangVersion
} else {
    Add-Check -Name 'LLVM/Clang' -Status 'warning' -Detail "$clangVersion; CI baseline is LLVM 15.0.6"
}

$nasmVersion = Get-FirstLine -Command 'nasm' -Arguments @('-v')
if ($nasmVersion) {
    Add-Check -Name 'NASM' -Status 'ok' -Detail $nasmVersion
} else {
    Add-Check -Name 'NASM' -Status 'blocked' -Detail 'nasm is not available'
}

$javaVersion = Get-FirstLine -Command 'java' -Arguments @('-version')
if (-not $javaVersion) {
    Add-Check -Name 'Java' -Status 'blocked' -Detail 'Java 17 or newer is required'
} elseif ($javaVersion -match '(version "1\.[0-8]\.|version "(?:9|1[0-6])\.)') {
    Add-Check -Name 'Java' -Status 'blocked' -Detail "$javaVersion; Java 17 or newer is required"
} else {
    Add-Check -Name 'Java' -Status 'ok' -Detail $javaVersion
}

$vsRoot = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\BuildTools'
$cl = Get-ChildItem (Join-Path $vsRoot 'VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe') -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending |
    Select-Object -First 1
if ($cl) {
    Add-Check -Name 'MSVC x64' -Status 'ok' -Detail $cl.FullName
} else {
    Add-Check -Name 'MSVC x64' -Status 'blocked' -Detail 'Visual Studio 2022 x64 compiler was not found'
}

$androidSdk = $env:ANDROID_SDK_ROOT
if (-not $androidSdk) {
    $androidSdk = $env:ANDROID_HOME
}
if (-not $androidSdk -or -not (Test-Path -LiteralPath $androidSdk)) {
    Add-Check -Name 'Android SDK' -Status 'blocked' -Detail 'ANDROID_SDK_ROOT/ANDROID_HOME does not point to a directory'
} else {
    Add-Check -Name 'Android SDK' -Status 'ok' -Detail $androidSdk
    $ndkProperties = Join-Path $androidSdk 'ndk\28.2.13676358\source.properties'
    if (Test-Path -LiteralPath $ndkProperties) {
        $releaseName = Get-Content -LiteralPath $ndkProperties |
            Where-Object { $_ -match '^Pkg\.ReleaseName\s*=' } |
            Select-Object -First 1
        Add-Check -Name 'Android NDK' -Status 'ok' -Detail ([string]$releaseName)
    } else {
        Add-Check -Name 'Android NDK' -Status 'blocked' -Detail 'NDK r28c (28.2.13676358) was not found'
    }
}

$vcpkgRoot = $env:VCPKG_ROOT
if ($vcpkgRoot -and (Test-Path -LiteralPath (Join-Path $vcpkgRoot '.git'))) {
    $vcpkgCommit = (& git -C $vcpkgRoot rev-parse HEAD 2>$null)
    if ($vcpkgCommit -eq '9e593bb18ea69cc5095e012465dcd675a822ed0d') {
        Add-Check -Name 'vcpkg' -Status 'ok' -Detail $vcpkgCommit
    } else {
        Add-Check -Name 'vcpkg' -Status 'warning' -Detail "$vcpkgCommit; expected 9e593bb18ea69cc5095e012465dcd675a822ed0d"
    }
} else {
    Add-Check -Name 'vcpkg' -Status 'blocked' -Detail 'VCPKG_ROOT is not configured to a Git checkout'
}

foreach ($generatedFile in @(
    'src\bridge_generated.rs',
    'src\bridge_generated.io.rs',
    'flutter\lib\generated_bridge.dart',
    'flutter\lib\generated_bridge.freezed.dart'
)) {
    $fullPath = Join-Path $repoRoot $generatedFile
    if (Test-Path -LiteralPath $fullPath) {
        Add-Check -Name "Generated: $generatedFile" -Status 'ok' -Detail 'present'
    } else {
        Add-Check -Name "Generated: $generatedFile" -Status 'blocked' -Detail 'run the bridge generation job first'
    }
}

$origin = (& git -C $repoRoot remote get-url origin 2>$null)
if ($LASTEXITCODE -eq 0 -and $origin) {
    Add-Check -Name 'Git origin' -Status 'ok' -Detail ([string]$origin)
} else {
    Add-Check -Name 'Git origin' -Status 'warning' -Detail 'no product repository remote is configured'
}

if ($Json) {
    $checks | ConvertTo-Json -Depth 3
} else {
    $checks | Format-Table -AutoSize -Wrap
}

if ($checks.status -contains 'blocked') {
    exit 1
}
