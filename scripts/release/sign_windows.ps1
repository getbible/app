# Sign staged executables before packaging/checksums. Credentials are provided
# only to trusted release jobs; passwords never appear in SignTool arguments.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string[]]$Paths)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Windows signing requires a Windows host.' }
if ($env:GITHUB_EVENT_NAME -like 'pull_request*') { throw 'Signing is prohibited in pull request jobs.' }
if (-not $env:WINDOWS_SIGNING_CERTIFICATE_BASE64 -or -not $env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD) {
    throw 'Windows signing requires the complete certificate/password secret set.'
}
$timestampUrl = if ($env:WINDOWS_TIMESTAMP_URL) { $env:WINDOWS_TIMESTAMP_URL } else { 'http://timestamp.digicert.com' }
$timestampUri = [Uri]$timestampUrl
if (-not $timestampUri.IsAbsoluteUri -or $timestampUri.Scheme -notin @('http', 'https') -or $timestampUri.UserInfo) {
    throw 'WINDOWS_TIMESTAMP_URL must be an absolute HTTP(S) RFC3161 endpoint without credentials.'
}
$signToolCommand = Get-Command signtool.exe -ErrorAction SilentlyContinue
$signTool = if ($signToolCommand) { $signToolCommand.Source } else {
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $candidates = @(Get-ChildItem -Path "$kits\*\x64\signtool.exe" | Sort-Object FullName -Descending)
    if ($candidates.Count -eq 0) { throw 'SignTool is missing; install the Windows SDK.' }
    $candidates[0].FullName
}
$files = @($Paths | ForEach-Object {
    $item = Get-Item -LiteralPath $_
    if ($item.PSIsContainer) {
        Get-ChildItem -LiteralPath $item.FullName -Recurse -File | Where-Object Extension -In @('.exe', '.dll')
    } else { $item }
} | Sort-Object FullName -Unique)
if ($files.Count -eq 0) { throw 'No executable files were selected for signing.' }

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('getbible-signing-' + [Guid]::NewGuid().ToString('N'))
$importedThumbprint = $null
$certificate = $null
$password = $null
$bytes = $null
try {
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = Get-Acl -LiteralPath $temporaryDirectory
    $acl.SetAccessRuleProtection($true, $false)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $temporaryDirectory -AclObject $acl
    $pfxPath = Join-Path $temporaryDirectory 'certificate.pfx'
    $bytes = [Convert]::FromBase64String($env:WINDOWS_SIGNING_CERTIFICATE_BASE64)
    [IO.File]::WriteAllBytes($pfxPath, $bytes)
    $password = ConvertTo-SecureString $env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD -AsPlainText -Force
    $pfxData = Get-PfxData -FilePath $pfxPath -Password $password
    if (@($pfxData.EndEntityCertificates).Count -ne 1) {
        throw 'Use a PFX containing exactly one publisher certificate and its certificate chain.'
    }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $bytes, $password, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    if (-not $certificate.HasPrivateKey) { throw 'Certificate contains no private key.' }
    if ($certificate.NotAfter -le [DateTime]::Now -or $certificate.NotBefore -gt [DateTime]::Now) {
        throw 'The signing certificate is not currently valid.'
    }
    $certificatePath = 'Cert:\CurrentUser\My\' + $certificate.Thumbprint
    if (Test-Path -LiteralPath $certificatePath) {
        if (-not (Get-Item -LiteralPath $certificatePath).HasPrivateKey) {
            throw 'An existing certificate has no private key; use a clean signing runner.'
        }
    } else {
        # Record before import so a partial import also reaches cleanup.
        $importedThumbprint = $certificate.Thumbprint
        Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation 'Cert:\CurrentUser\My' -Password $password | Out-Null
    }
    foreach ($file in $files) {
        # Preserve valid vendor signatures in the redistributable runtime.
        if ((Get-AuthenticodeSignature -LiteralPath $file.FullName).Status -eq 'Valid') { continue }
        & $signTool sign /q /sha1 $certificate.Thumbprint /s My /fd SHA256 /tr $timestampUrl /td SHA256 $file.FullName
        if ($LASTEXITCODE -ne 0) { throw 'SignTool signing/timestamping failed.' }
        & $signTool verify /q /pa /all $file.FullName
        if ($LASTEXITCODE -ne 0) { throw 'SignTool Authenticode verification failed.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
        if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate) {
            throw 'A valid timestamped Authenticode signature was not produced.'
        }
        Write-Host ('Signed and verified: ' + $file.Name)
    }
} finally {
    if ($certificate) { $certificate.Dispose() }
    if ($password) { $password.Dispose() }
    if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    # Keep an existing developer certificate; remove only the key imported here.
    try {
        if ($importedThumbprint) {
            $importedPath = 'Cert:\CurrentUser\My\' + $importedThumbprint
            if (Test-Path -LiteralPath $importedPath) { Remove-Item -LiteralPath $importedPath -DeleteKey -Force }
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryDirectory) { Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force }
    }
}
