# Dear Machine release installer for Windows x64, rendered for one GitHub
# release by render-release-installers.py. Do not publish it unrendered.
# Works when saved and run, or when piped to Invoke-Expression.
function Install-DearMachineRelease {
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version Latest
  $repository = @REPOSITORY@
  $tag = @TAG@
  $sourceRef = @SOURCE_REF@
  $signerWorkflow = @SIGNER_WORKFLOW@
  $downloadUrl = @DOWNLOAD_URL@
  $target = 'windows-x64'
  $archive = "dearmachine-$tag-$target.zip"
  $destination = Join-Path $env:LOCALAPPDATA 'DearMachine'

  if ($env:OS -ne 'Windows_NT' -or ![Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'Dear Machine needs native x64 PowerShell on Windows 11 x64.'
  }
  # Keep extraction paths short; the runtime has deep dependency paths.
  $cache = Join-Path $env:LOCALAPPDATA 'DearMachineBuild'
  $work = Join-Path $cache ('r-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  try {
    $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue
    $verified = $false
    if (!$gh) {
      if (!(Confirm-Unverified 'missing')) { return }
    } elseif (!(Test-GhSupported $gh.Source)) {
      if (!(Confirm-Unverified 'outdated')) { return }
    } elseif ((Invoke-Native $gh.Source @('auth', 'status')).Status -ne 0) {
      if (!(Confirm-Unverified 'signed-out')) { return }
    } else {
      $verified = $true
    }

    $sums = Join-Path $work 'SHA256SUMS'
    if ($verified) {
      Write-Host "Downloading the checksums for Dear Machine $tag..."
      & $gh.Source release download $tag --repo $repository --pattern SHA256SUMS --dir $work
      if ($LASTEXITCODE -ne 0) { throw 'Could not download the release checksums. Check your connection and try again.' }
      Write-Host 'Checking that this release was built by the official release workflow...'
      $check = Invoke-Native $gh.Source @('attestation', 'verify', $sums, '--repo', $repository,
        '--signer-workflow', $signerWorkflow, '--source-ref', $sourceRef, '--deny-self-hosted-runners')
      if ($check.Status -ne 0) {
        $check.Output | Out-Host
        throw 'This release could not be verified, so nothing was installed. Please report this to the Dear Machine maintainers.'
      }
      Write-Host 'Release verified.'
    } else {
      Get-ReleaseFile $downloadUrl 'SHA256SUMS' $work
    }
    $expected = $null
    foreach ($line in [IO.File]::ReadAllLines($sums)) {
      if ($line -match '^([0-9a-f]{64}) [ *](.+)$' -and $Matches[2] -eq $archive) { $expected = $Matches[1]; break }
    }
    if (!$expected) { throw "Release $tag has no download for $target yet. Nothing was installed." }

    Write-Host "Downloading Dear Machine $tag for $target..."
    if ($verified) {
      & $gh.Source release download $tag --repo $repository --pattern $archive --dir $work
      if ($LASTEXITCODE -ne 0) { throw 'The download did not complete. Check your connection and try again.' }
    } else {
      Get-ReleaseFile $downloadUrl $archive $work
    }
    $zip = Join-Path $work $archive
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant() -ne $expected) {
      throw "$archive does not match the release checksums, so nothing was installed."
    }

    $bundle = Join-Path $work 'b'
    Expand-ReleaseZip $zip $bundle
    Remove-Item -LiteralPath $zip -Force
    $installer = Join-Path $bundle 'source\scripts\install-windows.ps1'
    if (!(Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'The release bundle is incomplete. Nothing was installed.' }
    $arguments = @{ Bundle = $bundle; Destination = $destination }
    if (Test-Path -LiteralPath (Join-Path $destination 'windows-installation.json') -PathType Leaf) { $arguments.Update = $true }
    & $installer @arguments
  } finally {
    $node = Join-Path $work 'b\runtime\node\node.exe'
    $files = Join-Path $work 'b\source\scripts\windows-files.cjs'
    if ((Test-Path -LiteralPath $node) -and (Test-Path -LiteralPath $files)) {
      # PowerShell 5.1 cannot remove the runtime's long dependency paths.
      & $node $files remove $work
      if ($LASTEXITCODE -ne 0) { Write-Warning "Temporary files were left in $work" }
    } elseif (Test-Path -LiteralPath $work) {
      Remove-Item -LiteralPath $work -Recurse -Force
    }
  }
}

# Windows PowerShell turns redirected native stderr into terminating errors
# under ErrorActionPreference Stop; capture it as text instead.
function Invoke-Native([string]$Program, [string[]]$Arguments) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $Program @Arguments 2>&1 | ForEach-Object { "$_" }
    return @{ Status = $LASTEXITCODE; Output = $output }
  } finally { $ErrorActionPreference = $previous }
}

# gh 2.68.0 is the oldest release with --source-ref that also reads the
# current Sigstore trusted root.
function Test-GhSupported([string]$Program) {
  $version = Invoke-Native $Program @('--version')
  if ($version.Status -ne 0 -or "$($version.Output)" -notmatch 'gh version (\d+)\.(\d+)\.') { return $false }
  return ([int]$Matches[1] -gt 2) -or ([int]$Matches[1] -eq 2 -and [int]$Matches[2] -ge 68)
}

function Get-ReleaseFile([string]$BaseUrl, [string]$Name, [string]$Directory) {
  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  & $curl -q --fail --location --proto-redir '=https' --connect-timeout 30 --retry 2 --silent --show-error `
    --output (Join-Path $Directory $Name) --url "$BaseUrl/$Name"
  if ($LASTEXITCODE -ne 0) { throw "Could not download $Name. Check your connection and try again." }
}

function Expand-ReleaseZip([string]$Archive, [string]$Destination) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
  $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
  try {
    # Validate every entry before anything is written.
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('\', '/')
      if ($name.StartsWith('/') -or $name.Contains(':') -or ($name.Split('/') -contains '..') -or
          (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'The release archive contains an unsafe entry. Nothing was installed.' }
    }
  } finally { $zip.Dispose() }
  New-Item -ItemType Directory -Path $Destination | Out-Null
  # Windows' bsdtar handles the runtime's long dependency paths.
  & (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $Archive -C $Destination
  if ($LASTEXITCODE -ne 0) { throw 'The release archive could not be extracted. Nothing was installed.' }
}

function Confirm-Unverified([string]$Reason) {
  if ($Reason -eq 'missing') {
    $why = "It uses GitHub's free gh tool for that check, and gh isn't installed on this computer."
    $steps = @(
      '  1. Install gh: winget install --id GitHub.cli',
      '     (or follow https://cli.github.com), then open a new PowerShell window',
      '  2. Sign in with: gh auth login',
      '  3. Run this installer again.')
  } elseif ($Reason -eq 'outdated') {
    $why = "It uses GitHub's gh tool for that check, and the gh on this computer is too old to do it. Version 2.68.0 or newer is needed."
    $steps = @(
      '  1. Update gh: winget upgrade --id GitHub.cli',
      '     (or follow https://cli.github.com), then open a new PowerShell window',
      "  2. Sign in if you haven't yet: gh auth login",
      '  3. Run this installer again.')
  } else {
    $why = "It uses GitHub's gh tool for that check. gh is installed, but it isn't signed in to GitHub yet."
    $steps = @('  1. Sign in with: gh auth login', '  2. Run this installer again.')
  }
  Write-Host ''
  Write-Host 'Before installing, this installer normally checks that Dear Machine really'
  Write-Host "came from its official release process and wasn't changed along the way."
  Write-Host $why
  Write-Host ''
  Write-Host 'The safest choice is to stop here and set up gh. It only takes a minute:'
  Write-Host ''
  $steps | ForEach-Object { Write-Host $_ }
  Write-Host ''
  Write-Host "If you'd rather continue now, the installer will still compare the download with"
  Write-Host "the release's published checksums. That catches a damaged download, but it"
  Write-Host "can't tell whether someone changed the files on purpose."
  Write-Host ''
  if (![Environment]::UserInteractive -or [Console]::IsInputRedirected) {
    throw 'There is no terminal to confirm with, so nothing was installed.'
  }
  $answer = Read-Host 'Type yes to continue without the check, or press Enter to stop'
  if ($answer -cne 'yes') {
    Write-Host 'Stopped. Nothing was installed.'
    return $false
  }
  Write-Host 'Continuing without the release check.'
  return $true
}

Install-DearMachineRelease
