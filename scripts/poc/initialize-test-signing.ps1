[CmdletBinding()]
param(
    [string]$Repository = 'yyy779383-ui/remote-control-poc'
)

$ErrorActionPreference = 'Stop'
$signingDirectory = Join-Path $env:LOCALAPPDATA 'RemoteControlPOC\Signing'
$keystorePath = Join-Path $signingDirectory 'android-poc.p12'
$credentialPath = Join-Path $signingDirectory 'android-poc-password.xml'
$keyAlias = 'remote-control-poc'
$keytool = (Get-Command keytool -ErrorAction Stop).Source
$gh = (Get-Command gh -ErrorAction Stop).Source

function Set-RepositorySecret {
    param([string]$Name, [string]$Value)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $gh
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('secret', 'set', $Name, '--repo', $Repository)) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.Write($Value)
        $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEnd()
        $errorOutput = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Unable to store GitHub secret $Name. $errorOutput"
        }
        Write-Output "Configured repository secret: $Name"
    } finally {
        $process.Dispose()
    }
}

if ((Test-Path -LiteralPath $keystorePath) -xor (Test-Path -LiteralPath $credentialPath)) {
    throw "Signing files are incomplete at $signingDirectory. Restore the matching files before retrying."
}

if (-not (Test-Path -LiteralPath $keystorePath)) {
    New-Item -ItemType Directory -Path $signingDirectory -Force | Out-Null
    $randomBytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($randomBytes)
    $password = [Convert]::ToBase64String($randomBytes)
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    $credential = [pscredential]::new($keyAlias, $securePassword)
    $env:REMOTE_CONTROL_POC_KEYTOOL_PASSWORD = $password
    try {
        & $keytool -genkeypair -noprompt -storetype PKCS12 -keystore $keystorePath `
            -alias $keyAlias -keyalg RSA -keysize 3072 -validity 10950 `
            -dname 'CN=Remote Control POC Test, O=Remote Control POC, C=SG' `
            -storepass:env REMOTE_CONTROL_POC_KEYTOOL_PASSWORD `
            -keypass:env REMOTE_CONTROL_POC_KEYTOOL_PASSWORD
        if ($LASTEXITCODE -ne 0) { throw 'Test keystore generation failed.' }
        # Windows DPAPI binds the password backup to the current Windows account.
        $credential | Export-Clixml -LiteralPath $credentialPath
    } finally {
        Remove-Item Env:REMOTE_CONTROL_POC_KEYTOOL_PASSWORD -ErrorAction SilentlyContinue
    }
} else {
    $credential = Import-Clixml -LiteralPath $credentialPath
    $password = $credential.GetNetworkCredential().Password
}

$keystoreBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($keystorePath))
Set-RepositorySecret -Name 'ANDROID_POC_KEYSTORE_BASE64' -Value $keystoreBase64
Set-RepositorySecret -Name 'ANDROID_POC_STORE_PASSWORD' -Value $password
Set-RepositorySecret -Name 'ANDROID_POC_KEY_PASSWORD' -Value $password
Set-RepositorySecret -Name 'ANDROID_POC_KEY_ALIAS' -Value $keyAlias
Write-Output "Reusable test signing is ready. Local backup: $signingDirectory"
