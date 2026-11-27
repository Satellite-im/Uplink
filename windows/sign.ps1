# Signs one file with the Azure Artifact Signing certificate (Matt, 2026-11-19: "give me the steps I need to do to get
# the windows build deployed without the warning when downloading so it can be signed"). Inno Setup calls it for the
# installer and its uninstaller (windows/installer.iss, SignTool=ghost); .github/workflows/messaging-windows.yml has
# signed the app's own files before then, with Azure/artifact-signing-action, which also installed the ArtifactSigning
# module this uses. The account, profile and endpoint come from the workflow's environment, and the sign-in from the
# AZURE_TENANT_ID / AZURE_CLIENT_ID / AZURE_CLIENT_SECRET it sets (or the runner's `az login` where there is no secret).
param([Parameter(Mandatory = $true)][string] $File)

$ErrorActionPreference = 'Stop'
Import-Module ArtifactSigning
Invoke-ArtifactSigning `
  -Endpoint $env:AZURE_SIGNING_ENDPOINT `
  -CodeSigningAccountName $env:AZURE_SIGNING_ACCOUNT `
  -CertificateProfileName $env:AZURE_SIGNING_PROFILE `
  -Files $File `
  -FileDigest SHA256 `
  -TimestampRfc3161 'http://timestamp.acs.microsoft.com' `
  -TimestampDigest SHA256 `
  -Description 'Uplink' `
  -DescriptionUrl 'https://gogho.st'
$sig = Get-AuthenticodeSignature -FilePath $File
if ($sig.Status -ne 'Valid') { throw "$File is not signed ($($sig.Status): $($sig.StatusMessage))" }
Write-Host "signed $File by $($sig.SignerCertificate.Subject)"
