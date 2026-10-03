<#
  build.ps1 - Offline build of a bootable, driver-included qcow2 from a Win11 ARM64 ISO + drivers.
  No Setup, no qemu boot: DISM apply-image + offline driver injection (no signature prompt) + bcdboot + bcdedit.
  First boot runs OOBE via unattend to create USER/autologon (non-interactive).

  Requirements: x64 Windows (Administrator); built-in dism/bcdboot/diskpart; qemu-img (QEMU for Windows, on PATH).
  Entry point: ..\windows_build.ps1 sets $env:SRC_ISO / $DRIVERS_DIR / ... then calls this. To run build.ps1 directly,
  set those $env: vars first, then (as Administrator):  powershell -ExecutionPolicy Bypass -File build.ps1
  Cross-arch note: x64 host applying/injecting an ARM64 image + bcdboot usually works; if not, use ARM64 Windows/WinPE.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# This process only (see ..\windows_build.ps1): scripts called from here (pack-vmpkg.ps1) don't prompt again.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# --- Command echo helpers: print the command before executing it ---
function Format-CommandArg([AllowNull()][object]$Arg) {
    if ($null -eq $Arg) { return "''" }
    $s = [string]$Arg
    if ($s -eq '') { return "''" }
    if ($s -match '^[A-Za-z0-9_./:\\=-]+$') { return $s }
    return "'" + ($s -replace "'", "''") + "'"
}

function Format-CommandLine([string]$Command, [object[]]$Arguments = @()) {
    $parts = @((Format-CommandArg $Command))
    foreach ($a in $Arguments) { $parts += (Format-CommandArg $a) }
    return ($parts -join ' ')
}

function Show-CommandLine([string]$Command, [object[]]$Arguments = @()) {
    Write-Host ("> " + (Format-CommandLine $Command $Arguments)) -ForegroundColor DarkCyan
}


# --- Requires Administrator (diskpart/dism/bcdboot/mount all need it) ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Administrator required, relaunching elevated..." -ForegroundColor Yellow
    # UAC starts the child in System32 whatever the caller's directory was: hand the current directory over
    # on the command line and cd back to it before the script runs.
    $cwd = (Get-Location).ProviderPath.Replace("'", "''")
    $me = $PSCommandPath.Replace("'", "''")
    $elevArgs = "-ExecutionPolicy Bypass -Command `"Set-Location -LiteralPath '$cwd'; & '$me'`""
    Show-CommandLine "Start-Process" @("powershell", $elevArgs, "-Verb", "RunAs")
    Start-Process powershell $elevArgs -Verb RunAs
    exit
}

$HERE = $PSScriptRoot
$ROOT = Split-Path $HERE -Parent

# --- File-type input resolution: URL -> download into files\ then use; local path -> use directly; zip -> extract into files\ (goes through the file handling flow) ---
function Resolve-InputFile([string]$Src, [string]$SaveAs = "") {
    if ($Src -match '^https?://') {
        $files = Join-Path $HERE "files"
        New-Item -ItemType Directory -Force $files | Out-Null
        if (-not $SaveAs) { $SaveAs = Split-Path ($Src -replace '\?.*$', '') -Leaf }
        $dst = Join-Path $files $SaveAs
        if (Test-Path $dst) { Write-Host "[files] already exists, skip download: $dst" }
        else {
            Write-Host "[files] download $Src -> $dst"
            Invoke-WebRequest -Uri $Src -OutFile "$dst.part" -UseBasicParsing
            Move-Item "$dst.part" $dst -Force
        }
        return $dst
    }
    # %VAR% is expanded (PowerShell itself never does), relative paths count from the repo root (where
    # windows_build.ps1 lives), and the result is always a full path: CIM cmdlets such as Mount-DiskImage
    # ignore PowerShell's current location and fail on a relative one.
    $Src = [Environment]::ExpandEnvironmentVariables($Src)
    if (-not [IO.Path]::IsPathRooted($Src)) { $Src = Join-Path $ROOT $Src }
    if (-not (Test-Path -LiteralPath $Src)) { throw "file not found: $Src" }
    return (Resolve-Path -LiteralPath $Src).ProviderPath
}

# Driver zip/folder source -> the "root directory" after extraction. DRIVER_DIR / DRIVER_CERT reference this root via the ZIP/ prefix (mirrors macOS).
function Resolve-ZipRoot([string]$Src) {
    $p = Resolve-InputFile $Src "gunyah-arm64-drivers.zip"
    if (Test-Path $p -PathType Container) { return $p }
    if ($p -like "*.zip") {
        $dir = Join-Path (Join-Path $HERE "files") ([IO.Path]::GetFileNameWithoutExtension($p))
        if (Test-Path $dir) { Write-Host "[files] already extracted: $dir" }
        else { Write-Host "[files] extract $p -> $dir"; Expand-Archive $p -DestinationPath $dir -Force }
        return $dir
    }
    throw "driver source is neither a folder nor a zip: $p"
}

# Expand a leading ZIP prefix in DRIVER_DIR / DRIVER_CERT -> the zip extraction root (mirrors macOS's ${VAR/#ZIP/$ZIP}).
# e.g.: ZIP/drivers -> <root>\drivers; ZIP/DroidVM_Test.cer -> <root>\DroidVM_Test.cer; non-ZIP prefix -> unchanged.
function Expand-ZipToken([string]$Path, [string]$ZipRoot) {
    if (-not $Path) { return $Path }
    if ($Path -eq 'ZIP') { return $ZipRoot }
    # String concatenation (not Join-Path, to avoid 'C:' being resolved as a PSDrive); normalize slashes after ZIP to backslashes.
    if ($Path -match '^ZIP[\\/](.*)$') { return ($ZipRoot.TrimEnd('\', '/') + '\' + ($Matches[1] -replace '/', '\')) }
    if (-not [IO.Path]::IsPathRooted($Path)) { return (Join-Path $ROOT $Path) }   # plain relative: from the repo root
    return $Path
}

# qemu-img: QEMU for Windows installs to %ProgramFiles%\qemu without touching PATH, so look there before giving
# up. When it is missing, offer 'winget install SoftwareFreedomConservancy.QEMU' (a current qemu-img with zstd;
# the 'cloudbase.qemu-img' package on winget is 2.3.0 and cannot write compression_type=zstd). QEMU_IMG_INSTALL=1
# skips the question; 0/false/no/off or unset asks.
function Ensure-QemuImg([string]$AutoInstall) {
    $qemuDir = Join-Path $env:ProgramFiles "qemu"
    if (-not (Get-Command qemu-img -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $qemuDir "qemu-img.exe"))) {
        $env:PATH = "$qemuDir;" + $env:PATH
    }
    if (Get-Command qemu-img -ErrorAction SilentlyContinue) { return }
    $pkg = "SoftwareFreedomConservancy.QEMU"
    if ($AutoInstall) {
        Write-Host "[qemu-img] not found; QEMU_IMG_INSTALL is set -> winget install $pkg" -ForegroundColor Yellow
    } else {
        $ans = Read-Host "[qemu-img] not found. Install QEMU for Windows now (winget install $pkg)? [y/N]"
        if ($ans -notmatch '^\s*y(es)?\s*$') {
            throw "qemu-img not found: install QEMU for Windows (winget install $pkg) or set QEMU_IMG_INSTALL=1 to let the build install it"
        }
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw "winget not found; install QEMU for Windows by hand: https://www.qemu.org/download/#windows" }
    $wargs = @("install", "--id", $pkg, "-e", "--accept-source-agreements", "--accept-package-agreements")
    Show-CommandLine "winget" $wargs
    & winget @wargs
    # Not gated on winget's exit code ("already installed" is non-zero too): what matters is the binary.
    $env:PATH = "$qemuDir;" + $env:PATH
    if (-not (Get-Command qemu-img -ErrorAction SilentlyContinue)) { throw "qemu-img still not found after winget (expected $qemuDir\qemu-img.exe; winget exit code $LASTEXITCODE)" }
    Write-Host "[qemu-img] $((Get-Command qemu-img).Source)" -ForegroundColor Green
}

# --- Helpers ---
# Native commands (diskpart/dism/bcdboot/bcdedit/qemu-img) do NOT honor $ErrorActionPreference,
# so a non-zero exit is otherwise silently swallowed by "| Out-Null". Call this right after them.
function Assert-Exit([string]$what) {
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit code $LASTEXITCODE)" }
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [object[]]$ArgumentList = @(),
        [switch]$OutNull,
        [string]$What = ''
    )

    Show-CommandLine $FilePath $ArgumentList
    if ($OutNull) {
        & $FilePath @ArgumentList | Out-Null
    }
    else {
        & $FilePath @ArgumentList
    }

    if ($What) { Assert-Exit $What }
}

function Invoke-DiskPartScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$OutNull
    )

    Show-CommandLine "diskpart" @("/s", $Path)
    Write-Host "> diskpart script:" -ForegroundColor DarkCyan
    Get-Content $Path | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor DarkCyan }

    if ($OutNull) {
        & diskpart /s $Path | Out-Null
    }
    else {
        & diskpart /s $Path
    }
}


# Pick a drive letter that is genuinely free. "Free" must also exclude letters that are merely
# RESERVED in MountedDevices (left behind by a previously detached VHDX) - diskpart refuses to
# 'assign' those with "The specified drive letter is not free to be assigned", even though no
# volume currently shows them.
function Get-FreeDriveLetter([string[]]$Exclude = @()) {
    $used = New-Object System.Collections.Generic.HashSet[string]
    foreach ($l in (Get-Volume -ErrorAction SilentlyContinue).DriveLetter) { if ($l) { [void]$used.Add("$l".ToUpper()) } }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name) { if ($d.Length -eq 1) { [void]$used.Add($d.ToUpper()) } }
    try {
        $md = Get-Item 'HKLM:\SYSTEM\MountedDevices' -ErrorAction SilentlyContinue
        if ($md) { foreach ($p in $md.Property) { if ($p -match '^\\DosDevices\\([A-Z]):$') { [void]$used.Add($Matches[1]) } } }
    } catch {}
    foreach ($e in $Exclude) { [void]$used.Add("$e".ToUpper()) }
    foreach ($c in @('W', 'X', 'Y', 'Z', 'V', 'U', 'T', 'S', 'R', 'Q', 'P', 'N', 'M', 'L', 'K', 'J', 'H', 'G')) {
        if (-not $used.Contains($c)) { return $c }
    }
    throw "no free drive letter available"
}

# Resolve the install.wim image index. IMAGE_INDEX <= 0 -> list editions and let the user pick.
# Uses Get-WindowsImage (native objects: ImageIndex/ImageName/ImageSize) - no text parsing.
function Resolve-ImageIndex([string]$wim, [int]$wanted) {
    Show-CommandLine "Get-WindowsImage" @("-ImagePath", $wim)
    $images = @(Get-WindowsImage -ImagePath $wim)
    $valid = @($images | ForEach-Object { [int]$_.ImageIndex })
    if ($wanted -gt 0) {
        if ($valid -notcontains $wanted) {
            throw ("IMAGE_INDEX=$wanted not in this ISO. Available: " +
                (($images | ForEach-Object { "$($_.ImageIndex)=$($_.ImageName)" }) -join ', '))
        }
        return $wanted
    }
    if ($images.Count -eq 1) {
        Write-Host "[image] one edition only -> index $($valid[0]) ($($images[0].ImageName))"
        return $valid[0]
    }
    Write-Host "`nEditions in install.wim:" -ForegroundColor Cyan
    foreach ($im in $images) {
        Write-Host ("  [{0}] {1}  ({2:N1} GB)" -f $im.ImageIndex, $im.ImageName, ($im.ImageSize / 1GB))
    }
    if ([Console]::IsInputRedirected) {
        # Non-interactive (CI). Pick Professional when the media has it: EditionId is language-neutral,
        # unlike ImageName which is localized (e.g. "专业版" on zh-cn media). IMAGE_INDEX still overrides.
        $pick = $images | Where-Object { $_.EditionId -eq 'Professional' } | Select-Object -First 1
        if (-not $pick) { $pick = $images | Where-Object { $_.ImageName -match 'Pro|专业版' } | Select-Object -First 1 }
        if (-not $pick) { $pick = $images[0] }
        Write-Host ("[image] no console: picked [{0}] {1} (EditionId={2}) of {3} - set IMAGE_INDEX to choose another" -f `
            $pick.ImageIndex, $pick.ImageName, $pick.EditionId, $images.Count) -ForegroundColor Yellow
        return [int]$pick.ImageIndex
    }
    do {
        $sel = (Read-Host "`nSelect image index").Trim()
        $n = 0
        $ok = [int]::TryParse($sel, [ref]$n) -and ($valid -contains $n)
        if (-not $ok) { Write-Host ("  invalid, choose from: " + ($valid -join ', ')) -ForegroundColor DarkYellow }
    } while (-not $ok)
    return $n
}

# --- Resolve config: environment variable (set by windows_build.ps1) > built-in default ---
$SRC_ISO     = if ($env:SRC_ISO)     { $env:SRC_ISO }          else { $null }
$DRIVERS_DIR = if ($env:DRIVERS_DIR) { $env:DRIVERS_DIR }      else { "https://github.com/Droid-VM/gunyah-guest-drivers-windows/releases/download/dev/gunyah-arm64-drivers.zip" }
$IMAGE_INDEX = if ($env:IMAGE_INDEX) { [int]$env:IMAGE_INDEX } else { 0 }       # 0 = list editions and prompt
$DISK_MB     = if ($env:DISK_SIZE_MB){ [int]$env:DISK_SIZE_MB }else { 40960 }
$OUT_QCOW    = if ($env:OUT_QCOW)    { $env:OUT_QCOW }         else { Join-Path $ROOT "win11-droidvm-final.qcow2" }
# Optional: also pack a ready-to-import .vmpkg (qcow2 + local VM config baked in) with pack-vmpkg.ps1
# (pure PowerShell + the built-in tar.exe). See repo README.
$OUT_VMPKG   = if ($env:OUT_VMPKG)   { $env:OUT_VMPKG }        else { "" }
$VMS_JSON    = if ($env:VMS_JSON)    { $env:VMS_JSON }         else { Join-Path $ROOT "vms.json" }
# %VAR% in output/config paths is expanded (PowerShell itself never does); relative ones resolve against the
# repo root, not the elevated shell's CWD (system32).
$OUT_QCOW  = [Environment]::ExpandEnvironmentVariables($OUT_QCOW)
$OUT_VMPKG = [Environment]::ExpandEnvironmentVariables($OUT_VMPKG)
$VMS_JSON  = [Environment]::ExpandEnvironmentVariables($VMS_JSON)
if (-not [IO.Path]::IsPathRooted($OUT_QCOW))                  { $OUT_QCOW  = Join-Path $ROOT $OUT_QCOW }
if ($OUT_VMPKG -and -not [IO.Path]::IsPathRooted($OUT_VMPKG)) { $OUT_VMPKG = Join-Path $ROOT $OUT_VMPKG }
if (-not [IO.Path]::IsPathRooted($VMS_JSON))                  { $VMS_JSON  = Join-Path $ROOT $VMS_JSON }
$VMPKG_COMPRESSION = if ($env:VMPKG_COMPRESSION) { $env:VMPKG_COMPRESSION } else { "auto" }   # auto = zstd on all cores when tar.exe has libzstd (Win11), else gzip
$VMPKG_THREADS = if ($env:VMPKG_THREADS) { [int]$env:VMPKG_THREADS } else { 0 }               # zstd threads, 0 = all
$COMPRESS    = if ($env:COMPRESS -and $env:COMPRESS -notmatch '^(0|false|no|off)$') { $env:COMPRESS } else { "" }   # 1 = zstd-compress the qcow2 clusters (step 9); 0/false/no/off/unset = off
$QEMU_IMG_INSTALL = if ($env:QEMU_IMG_INSTALL -and $env:QEMU_IMG_INSTALL -notmatch '^(0|false|no|off)$') { $env:QEMU_IMG_INSTALL } else { "" }   # 1 = winget-install QEMU without asking when qemu-img is missing
$LETTER_ESP  = if ($env:LETTER_ESP)  { $env:LETTER_ESP }       else { Get-FreeDriveLetter }
$LETTER_WIN  = if ($env:LETTER_WIN)  { $env:LETTER_WIN }       else { Get-FreeDriveLetter @($LETTER_ESP) }
# Driver install list/cert (mirrors macOS): DRIVER_DIR=directory containing the per-driver subfolders (ZIP/ = driver zip extraction root);
# DRIVER_INSTALL=offline-inject only these subfolders (empty=all); DRIVER_CERT=specify the signing cert (empty=auto-extract from .cat).
$DRIVER_DIR     = if ($env:DRIVER_DIR)     { $env:DRIVER_DIR }     else { "ZIP/drivers" }
$DRIVER_INSTALL = if ($env:DRIVER_INSTALL) { $env:DRIVER_INSTALL } else { "" }
$DRIVER_CERT    = if ($env:DRIVER_CERT)    { $env:DRIVER_CERT }    else { "" }
# EMS/SAC (Emergency Management Services): the interactive SAC> console needs the "EMS and SAC Toolset"
# Feature-on-Demand (sacdrv.sys/sacsess.exe/sacsvr) which the LTSC/Pro ARM64 image does NOT ship.
# EMS_SAC_SOURCE says where it comes from:
#   skip     (default) boot-EMS only: BCD EMS is always armed (boot-time serial text works), no interactive SAC>
#   online   a first-boot script pulls the FoD from Windows Update on the TARGET (network + one reboot)
#   <path>   the matching-build ARM64 FoD ISO mount or its extracted folder -> injected OFFLINE in
#            step 5c (deterministic, zero network, recommended)
$EMS_SAC_SOURCE  = if ($env:EMS_SAC_SOURCE)  { $env:EMS_SAC_SOURCE }  else { "skip" }
if (-not $env:EMS_SAC_SOURCE -and ($env:FOD_SOURCE -or $env:EMS_SAC_ONLINE)) {   # names before the merge
    $EMS_SAC_SOURCE = if ($env:FOD_SOURCE) { $env:FOD_SOURCE } else { "online" }
    Write-Host "[ems-sac] FOD_SOURCE / EMS_SAC_ONLINE were merged into EMS_SAC_SOURCE (skip | online | <FoD path>); using '$EMS_SAC_SOURCE'" -ForegroundColor DarkYellow
}
$emsSacOnline    = ($EMS_SAC_SOURCE -eq "online")
$EMS_SAC_CAP     = 'Windows.Desktop.EMS-SAC.Tools~~~~0.0.1.0'
# Account name. Use $env:DVM_USERNAME (not the built-in Windows $env:USERNAME = the current logged-in user). Unset -> USER.
$USERNAME     = if ($env:DVM_USERNAME) { $env:DVM_USERNAME } else { "USER" }
# Account password: network logon for RDP/SSH does not accept a blank password (Windows default LimitBlankPasswordUse=1). Use $env:DVM_PASSWORD
# (the @@PASSWORD@@ token is injected into unattend.xml, see step 8; the old $env:SSH_PASSWORD still works).
$PASSWORD     = if ($env:DVM_PASSWORD) { $env:DVM_PASSWORD } elseif ($env:SSH_PASSWORD) { $env:SSH_PASSWORD } else { "DroidVM" }
# SSH public key(s) (multiple allowed, newline-separated); empty = password login only. Passed via environment variable, not written to inputs\.
$SSH_PUBKEY   = if ($env:SSH_PUBKEY)   { $env:SSH_PUBKEY }      else { "" }
# OpenSSH installer source: URL (downloaded at build time) or local path (copied). Defaults to the arm64 .msi. Empty string = do not install SSH (RDP only).
$OPENSSH_SRC  = if ($env:OPENSSH_SRC)  { $env:OPENSSH_SRC }     else { "https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64-v10.0.0.0.msi" }
Write-Host "[disk] drive letters: ESP=$LETTER_ESP Windows=$LETTER_WIN"

foreach ($t in @("dism", "bcdboot", "diskpart")) {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "$t not found" }
}
Ensure-QemuImg $QEMU_IMG_INSTALL
if (-not $SRC_ISO) { throw "Invalid SRC_ISO: set the Win11 ARM64 ISO (URL or local path) in windows_build.ps1" }
$SRC_ISO = Resolve-InputFile $SRC_ISO "win11-arm64.iso"

$WORK = Join-Path $env:TEMP ("droidvm-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
Show-CommandLine "New-Item" @("-ItemType", "Directory", "-Force", $WORK)
New-Item -ItemType Directory -Force $WORK | Out-Null
$VHDX = Join-Path $WORK "w11.vhdx"
$isoMounted = $false; $vhdAttached = $false

function Cleanup {
    if ($script:vhdAttached) {
        # Release the drive letters first so they don't linger as stale MountedDevices reservations
        # that would make a later run's diskpart 'assign' fail. Best-effort.
        foreach ($L in @($script:LETTER_ESP, $script:LETTER_WIN)) {
            if ($L) {
                Show-CommandLine "cmd" @("/c", "mountvol ${L}: /D")
                & cmd /c "mountvol ${L}: /D" 2>$null | Out-Null
            }
        }
        $s = "select vdisk file=`"$VHDX`"`r`ndetach vdisk`r`nexit"
        $f = Join-Path $WORK "detach.txt"
        $s | Out-File -Encoding ascii $f
        Invoke-DiskPartScript -Path $f -OutNull
    }
    if ($script:isoMounted) {
        Show-CommandLine "Dismount-DiskImage" @("-ImagePath", $SRC_ISO)
        Dismount-DiskImage -ImagePath $SRC_ISO | Out-Null
    }
}

try {
    # === 1) Resolve driver source (URL -> download to files\; local zip/folder -> use directly; zip -> extract to files\) ===
    # Driver zip -> extraction root (ZIP); the ZIP/ prefix in DRIVER_DIR/DRIVER_CERT expands to that root directory.
    $zipRoot     = Resolve-ZipRoot $DRIVERS_DIR
    $DRIVER_DIR  = Expand-ZipToken $DRIVER_DIR  $zipRoot
    $DRIVER_CERT = Expand-ZipToken $DRIVER_CERT $zipRoot
    if (-not (Test-Path $DRIVER_DIR -PathType Container)) { throw "driver folder DRIVER_DIR not found: $DRIVER_DIR" }
    if ($DRIVER_CERT -and -not (Test-Path $DRIVER_CERT)) { throw "DRIVER_CERT not found: $DRIVER_CERT" }
    $drvDir = $DRIVER_DIR
    $instShow = if ($DRIVER_INSTALL) { $DRIVER_INSTALL } else { "(all)" }
    $certShow = if ($DRIVER_CERT) { Split-Path $DRIVER_CERT -Leaf } else { "(auto from .cat)" }
    Write-Host "[drivers] dir=$drvDir  install=$instShow  cert=$certShow"

    # === 2) Mount ISO, get install.wim, resolve image index ===
    Show-CommandLine "Mount-DiskImage" @("-ImagePath", $SRC_ISO, "-PassThru")
    $mr = Mount-DiskImage -ImagePath $SRC_ISO -PassThru; $isoMounted = $true
    $isoLetter = ($mr | Get-Volume).DriveLetter
    $wim = "${isoLetter}:\sources\install.wim"
    # Stock Windows media ships sources\install.wim, but repacked media (tiny11 and friends) ships the
    # compressed sources\install.esd instead. DISM reads/applies both, so take whichever is there.
    if (-not (Test-Path $wim)) {
        $esd = "${isoLetter}:\sources\install.esd"
        if (Test-Path $esd) {
            Write-Host "[iso] no sources\install.wim -> using the compressed sources\install.esd" -ForegroundColor DarkYellow
            $wim = $esd
        } else {
            throw "neither sources\install.wim nor sources\install.esd found in ISO ($SRC_ISO)"
        }
    }
    Write-Host "[iso] $SRC_ISO"
    $IMAGE_INDEX = Resolve-ImageIndex $wim $IMAGE_INDEX
    Write-Host "[image] using index $IMAGE_INDEX"

    # === 3) Create + attach VHDX, GPT partition: ESP(FAT32) + MSR + Windows(NTFS) ===
    Write-Host "[disk] creating and partitioning VHDX ..."
    $dp = @"
create vdisk file="$VHDX" maximum=$DISK_MB type=expandable
select vdisk file="$VHDX"
attach vdisk
convert gpt
create partition efi size=260
format fs=fat32 quick label=System
assign letter=$LETTER_ESP
create partition msr size=16
create partition primary
format fs=ntfs quick label=Windows
assign letter=$LETTER_WIN
exit
"@
    $dpFile = Join-Path $WORK "part.txt"
    $dp | Out-File -Encoding ascii $dpFile
    # diskpart exits 0 even when an 'assign letter' fails, so verify the volumes actually mounted.
    $dpOut = Invoke-DiskPartScript -Path $dpFile; $vhdAttached = $true
    $W = "${LETTER_WIN}:"; $S = "${LETTER_ESP}:"
    if (-not (Test-Path "$S\") -or -not (Test-Path "$W\")) {
        throw "diskpart did not mount $S and/or $W (likely a stale drive-letter reservation; set LETTER_ESP/LETTER_WIN to other letters). diskpart output:`n$(( $dpOut | Out-String ).Trim())"
    }

    # === 4) Apply image ===
    # install.wim applies directly; install.esd (solid LZMS) also applies directly on Win10+ DISM, but if
    # that ever fails we export it to a plain WIM in the work dir and apply that instead (one retry).
    Write-Host "[dism] applying $wim -> $W\ ..."
    try {
        Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Apply-Image", "/ImageFile:$wim", "/Index:$IMAGE_INDEX", "/ApplyDir:$W\") -OutNull -What "dism /Apply-Image"
    } catch {
        if ($wim -notmatch '\.esd$') { throw }
        Write-Host "  [warn] applying the ESD directly failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-Host "[dism] exporting install.esd -> install.wim, then re-applying ..." -ForegroundColor Yellow
        # A failed /Apply-Image leaves a partial tree behind -> wipe the volume first.
        Show-CommandLine "Format-Volume" @("-DriveLetter", $LETTER_WIN, "-FileSystem", "NTFS", '-Confirm:$false')
        Format-Volume -DriveLetter $LETTER_WIN -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false -Force | Out-Null
        $wimTemp = Join-Path $WORK "install.wim"
        Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Export-Image", "/SourceImageFile:$wim", "/SourceIndex:$IMAGE_INDEX", "/DestinationImageFile:$wimTemp", "/Compress:fast", "/CheckIntegrity") -OutNull -What "dism /Export-Image (esd -> wim)"
        $wim = $wimTemp
        Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Apply-Image", "/ImageFile:$wim", "/Index:$IMAGE_INDEX", "/ApplyDir:$W\") -OutNull -What "dism /Apply-Image"
    }

    # === 5) Offline driver injection (no signature prompt) ===
    # Offline-inject only the driver subfolders listed in DRIVER_INSTALL (empty=the whole $drvDir /Recurse). /ForceUnsigned skips the signature prompt.
    # Note: boot-critical drivers (viostor/vioscsi) must be included in DRIVER_INSTALL, otherwise the image will not boot.
    if ($DRIVER_INSTALL) {
        foreach ($d in ($DRIVER_INSTALL -split '\s+' | Where-Object { $_ })) {
            $sub = Join-Path $drvDir $d
            if (Test-Path $sub -PathType Container) {
                Write-Host "[dism] inject driver: $d"
                Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Image:$W\", "/Add-Driver", "/Driver:$sub", "/Recurse", "/ForceUnsigned") -OutNull -What "dism /Add-Driver $d"
            } else { Write-Host "  [warn] driver $d to install does not exist in $drvDir" -ForegroundColor DarkYellow }
        }
    } else {
        Write-Host "[dism] injecting all drivers offline ..."
        Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Image:$W\", "/Add-Driver", "/Driver:$drvDir", "/Recurse", "/ForceUnsigned") -OutNull -What "dism /Add-Driver"
    }

    # === 5b) Extract driver signer certs (offline) -> stage for first-boot trust ===
    # Offline injection (/ForceUnsigned) needs no cert, but that only lets "this batch" of drivers install. Later "interactive" driver updates
    # (Device Manager / pnputil / vendor installer) check TrustedPublisher; if the cert is absent -> the "cannot verify
    # publisher" prompt appears. Here we extract each distinct signer from the .cat, staging them to C:\DroidVM\certs, and unattend specialize then
    # imports them into Root+TrustedPublisher (mirrors macos/autounattend.xml). Note: this only removes the "install prompt"; self-signed drivers
    # still rely on BCD testsigning (step 7) to load at boot, so do not turn testsigning off because of this.
    Write-Host "[certs] staging driver signer cert(s) offline ..."
    $certDir = "$W\DroidVM\certs"
    New-Item -ItemType Directory -Force $certDir | Out-Null
    if ($DRIVER_CERT) {
        # Specified cert: just place it, and unattend specialize imports it into Root+TrustedPublisher (mirrors macOS's DRIVER_CERT).
        Copy-Item $DRIVER_CERT (Join-Path $certDir (Split-Path $DRIVER_CERT -Leaf)) -Force
        Write-Host "[certs] using the specified DRIVER_CERT: $(Split-Path $DRIVER_CERT -Leaf)"
    } else {
        # Not specified -> auto-extract every unique signer from the driver .cat/.sys
        # (.cat is most reliable: for catalog-signed drivers the .sys shows as unsigned when the catalog is not registered on the host, but the .cat itself reveals the signer)
        $seenThumb = @{}
        Get-ChildItem $drvDir -Recurse -Include *.cat, *.sys, *.dll, *.exe -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $cert = (Get-AuthenticodeSignature $_.FullName).SignerCertificate
                if ($cert -and -not $seenThumb.ContainsKey($cert.Thumbprint)) {
                    $seenThumb[$cert.Thumbprint] = $true
                    Export-Certificate -Cert $cert -FilePath (Join-Path $certDir "$($cert.Thumbprint).cer") | Out-Null
                }
            } catch {}
        }
        # Also collect any *.cer bundled directly in the driver package (e.g. DroidVM_Test.cer)
        Get-ChildItem $drvDir -Recurse -Filter *.cer -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $certDir $_.Name) -Force }
        Write-Host "[certs] auto-extracted $($seenThumb.Count) cert(s) from driver .cat -> $certDir"
    }

    # === 5c) EMS-SAC Feature-on-Demand (offline, for the interactive SAC> console) ===
    # The ARM64 LTSC/Pro image ships no SAC runtime; the "EMS and SAC Toolset" FoD provides
    # sacdrv.sys + sacsess.exe + the sacsvr service. Inject it offline from EMS_SAC_SOURCE (the
    # matching-build ARM64 FoD ISO mount or its extracted folder). Done BEFORE ResetBase so the
    # capability folds into the reset component base. Without a FoD path we DON'T fail the
    # build: BCD EMS (step 7b) still gives boot-time serial text, and the first-boot script
    # (staged below, step 8d) pulls it from Windows Update when EMS_SAC_SOURCE=online.
    switch ($EMS_SAC_SOURCE) {
        "skip"   { Write-Host "[ems-sac] EMS_SAC_SOURCE=skip: shipping boot-EMS only (no interactive SAC runtime)." -ForegroundColor DarkYellow }
        "online" { Write-Host "[ems-sac] EMS_SAC_SOURCE=online: the target's first boot will pull the FoD from Windows Update (needs network)." -ForegroundColor DarkYellow }
        default {
            $fodSrc = Resolve-InputFile $EMS_SAC_SOURCE
            Write-Host "[ems-sac] injecting FoD offline from $fodSrc ..."
            try {
                Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Image:$W\", "/Add-Capability", "/CapabilityName:$EMS_SAC_CAP", "/Source:$fodSrc", "/LimitAccess") -OutNull -What "dism /Add-Capability EMS-SAC"
                Write-Host "[ems-sac] FoD injected offline (SAC runtime present in image)" -ForegroundColor Green
            } catch {
                Write-Host "  [warn] offline FoD injection failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
                Write-Host "  [warn] check EMS_SAC_SOURCE points at the ARM64 FoD ISO/folder matching the image build" -ForegroundColor DarkYellow
            }
        }
    }

    # === 6) Debloat (offline removal of provisioned Appx) ===
    Write-Host "[debloat] removing extra provisioned Appx offline ..."
    $keep = 'VCLibs|NET\.Native|UI\.Xaml|Store|SecHealth|Photos|Notepad|Terminal|WindowsTerminal'
    try {
        Get-AppxProvisionedPackage -Path "$W\" | Where-Object { $_.DisplayName -notmatch $keep } | ForEach-Object {
            try {
                Show-CommandLine "Remove-AppxProvisionedPackage" @("-Path", "$W\", "-PackageName", $_.PackageName)
                Remove-AppxProvisionedPackage -Path "$W\" -PackageName $_.PackageName | Out-Null
            } catch {}
        }
    } catch { Write-Host "  (skipping debloat: $($_.Exception.Message))" -ForegroundColor DarkYellow }

    # === 6b) Offline shrink: WinSxS ResetBase + disable hibernate ===
    # Mirrors the macOS debloat's WinSxS compaction and hibernate disable, here using the offline version (no boot needed).
    # Purely to shrink the image; failure does not affect usability, so everything is set as non-fatal.
    Write-Host "[debloat] WinSxS component cleanup (ResetBase, offline) ..."
    try {
        Invoke-ExternalCommand -FilePath "dism" -ArgumentList @("/Image:$W\", "/Cleanup-Image", "/StartComponentCleanup", "/ResetBase") -OutNull -What "dism /Cleanup-Image /ResetBase"
    } catch {
        Write-Host "  (skipping ResetBase: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }

    Write-Host "[debloat] disabling hibernate offline (no hiberfil.sys) ..."
    # Offline edit of the SYSTEM hive: HibernateEnabled=0 -> first boot will not create hiberfil.sys.
    $sysHive = "$W\Windows\System32\config\SYSTEM"
    $hiveLoaded = $false
    try {
        Invoke-ExternalCommand -FilePath "reg" -ArgumentList @("load", "HKLM\DVMOFF", $sysHive) -OutNull -What "reg load SYSTEM hive"
        $hiveLoaded = $true
        foreach ($cs in @("ControlSet001", "ControlSet002")) {
            $pk = "HKLM\DVMOFF\$cs\Control\Power"
            reg query $pk *> $null
            if ($LASTEXITCODE -eq 0) {
                Show-CommandLine "reg add" @($pk, "/v", "HibernateEnabled", "/t", "REG_DWORD", "/d", "0", "/f")
                reg add $pk /v HibernateEnabled        /t REG_DWORD /d 0 /f *> $null
                reg add $pk /v HibernateEnabledDefault /t REG_DWORD /d 0 /f *> $null
            }
            # Enable RDP (offline): fDenyTSConnections=0. The firewall rule is opened separately at first boot by setup-ssh.ps1.
            $tk = "HKLM\DVMOFF\$cs\Control\Terminal Server"
            reg query $tk *> $null
            if ($LASTEXITCODE -eq 0) {
                Show-CommandLine "reg add" @($tk, "/v", "fDenyTSConnections", "/t", "REG_DWORD", "/d", "0", "/f")
                reg add $tk /v fDenyTSConnections /t REG_DWORD /d 0 /f *> $null
            }
        }
    } catch {
        Write-Host "  (skipping hibernate-off: $($_.Exception.Message))" -ForegroundColor DarkYellow
    } finally {
        # The hive must be unloaded, otherwise step 9 dismount VHDX will fail.
        if ($hiveLoaded) {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            reg unload HKLM\DVMOFF *> $null
        }
    }

    # === 6c) Disable Reserved Storage (offline) ===
    # Win11 images ship with ~7GB Reserved Storage that the reserve manager allocates on first boot. Setting
    # ShippedWithReserves=0 in the offline SOFTWARE hive (before the image ever boots) makes it treat the image as
    # shipped without reserves -> it never allocates them. Purely to save space; failure is non-fatal.
    # (sleep/display = Never is set on first boot via unattend.xml, since powercfg needs a running system.)
    Write-Host "[debloat] disabling Reserved Storage offline (ShippedWithReserves=0) ..."
    $softHive = "$W\Windows\System32\config\SOFTWARE"
    $softLoaded = $false
    try {
        Invoke-ExternalCommand -FilePath "reg" -ArgumentList @("load", "HKLM\DVMSOFT", $softHive) -OutNull -What "reg load SOFTWARE hive"
        $softLoaded = $true
        $rk = "HKLM\DVMSOFT\Microsoft\Windows\CurrentVersion\ReserveManager"
        Show-CommandLine "reg add" @($rk, "/v", "ShippedWithReserves", "/t", "REG_DWORD", "/d", "0", "/f")
        reg add $rk /v ShippedWithReserves /t REG_DWORD /d 0 /f *> $null
    } catch {
        Write-Host "  (skipping Reserved Storage disable: $($_.Exception.Message))" -ForegroundColor DarkYellow
    } finally {
        if ($softLoaded) {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            reg unload HKLM\DVMSOFT *> $null
        }
    }

    # === 7) Boot files + BCD (bcdboot uses the ARM64 bootmgr from the image) ===
    Write-Host "[boot] bcdboot + BCD ..."
    Invoke-ExternalCommand -FilePath "bcdboot" -ArgumentList @("$W\Windows", "/s", $S, "/f", "UEFI") -OutNull -What "bcdboot"
    $BCD = "$S\EFI\Microsoft\Boot\BCD"
    Invoke-ExternalCommand -FilePath "bcdedit" -ArgumentList @("/store", $BCD, "/set", "{default}", "testsigning", "on") -OutNull -What "bcdedit testsigning"
    Invoke-ExternalCommand -FilePath "bcdedit" -ArgumentList @("/store", $BCD, "/set", "{default}", "nointegritychecks", "on") -OutNull -What "bcdedit nointegritychecks"

    # === 7b) Emergency Management Services (EMS/SAC over the SBSA UART) ===
    # Turns the guest into an out-of-band serial console (SAC> prompt) on the app's SBSA
    # port. On ARM64 there is no legacy I/O COM numbering, so EMS pulls the port/baud from
    # the ACPI SPCR table (edk2 synthesizes SPCR from the SBSA UART FDT node) -> "/emssettings
    # BIOS" is the correct mode here, NOT EMSPORT:n. This only arms the loader/kernel; the
    # interactive SAC runtime (sacdrv.sys/sacsess.exe/sacsvr) is a separate Feature-on-Demand
    # injected in step 8d. For SAC to actually attach, the VM must launch with an SBSA serial
    # port marked as the guest console (crosvm stdout-path -> SPCR); see windows/README.md.
    Invoke-ExternalCommand -FilePath "bcdedit" -ArgumentList @("/store", $BCD, "/emssettings", "BIOS") -OutNull -What "bcdedit emssettings BIOS"
    Invoke-ExternalCommand -FilePath "bcdedit" -ArgumentList @("/store", $BCD, "/ems", "{default}", "on") -OutNull -What "bcdedit ems {default} on"
    Invoke-ExternalCommand -FilePath "bcdedit" -ArgumentList @("/store", $BCD, "/bootems", "{bootmgr}", "on") -OutNull -What "bcdedit bootems {bootmgr} on"

    # === 8) OOBE unattend (create USER / autologon) ===
    Show-CommandLine "New-Item" @("-ItemType", "Directory", "-Force", "$W\Windows\Panther")
    New-Item -ItemType Directory -Force "$W\Windows\Panther" | Out-Null
    $unattendSrc = Join-Path $HERE "unattend.xml"
    # Inject account/password (@@USERNAME@@ / @@PASSWORD@@ tokens). XML-escape keeps the XML valid when the credentials contain &<>"
    # (mirrors the macOS perl version). Write UTF-8 without BOM via .NET, matching the original file.
    $esc = { param($s) $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;') }
    $unattendXml = (Get-Content $unattendSrc -Raw).Replace('@@USERNAME@@', (& $esc $USERNAME)).Replace('@@PASSWORD@@', (& $esc $PASSWORD))
    Show-CommandLine "Set-Content" @("$W\Windows\Panther\unattend.xml", "(unattend.xml + password)")
    [System.IO.File]::WriteAllText("$W\Windows\Panther\unattend.xml", $unattendXml, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[oobe] unattend.xml placed (first boot creates USER, autologon, imports certs)"

    # === 8c) Stage SSH payload into image (offline) ===
    # setup-ssh.ps1 is run by unattend FirstLogonCommands at first boot (installing the sshd service requires online registration).
    $stage = "$W\DroidVM"
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item (Join-Path $HERE "setup-ssh.ps1") "$stage\setup-ssh.ps1" -Force
    # First-logon half of the debloat (telemetry / services / tasks / Windows Update off + desktop
    # enable_windows_update.bat); the offline half ran in step 6. Mirrors macos/debloat.ps1.
    Copy-Item (Join-Path $HERE "debloat.ps1") "$stage\debloat.ps1" -Force
    Write-Host "[debloat] staged debloat.ps1 (first logon: telemetry / services / tasks / Windows Update off)"
    # pvmpower devnode: pvmpower.sys binds to the root-enumerated ROOT\PVMPOWER, so the devnode must be created at first boot via SetupAPI
    # (INF/DISM injection does not create a devnode). Stage it if the driver zip has it, skip if not (older drivers lack pvmpower, which is normal).
    $pvmDevnode = Join-Path $zipRoot "pvmpower-devnode.ps1"
    if (Test-Path $pvmDevnode) { Copy-Item $pvmDevnode "$stage\pvmpower-devnode.ps1" -Force; Write-Host "[pvmpower] staged pvmpower-devnode.ps1" }
    # OpenSSH installer: $OPENSSH_SRC can be a URL (downloaded to files\) or a local path; empty = do not install SSH. After resolving, copy it into the image.
    # An arm64 .msi is recommended (sets up service/host key/firewall in one step); .zip is also accepted. Non-fatal: if it cannot be obtained, only RDP is set up.
    if ($OPENSSH_SRC) {
        try {
            $sshLocal = Resolve-InputFile $OPENSSH_SRC
            Copy-Item $sshLocal (Join-Path $stage (Split-Path $sshLocal -Leaf)) -Force
            Write-Host "[ssh] staged $(Split-Path $sshLocal -Leaf)"
        } catch {
            Write-Host "[ssh] OpenSSH staging failed -> RDP only: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "[ssh] `$OPENSSH_SRC empty -> do not install SSH (RDP only)" -ForegroundColor DarkYellow
    }
    # authorized_keys is provided by the $SSH_PUBKEY environment variable (multiple keys newline-separated), UTF-8 without BOM + LF.
    if ($SSH_PUBKEY) {
        $akText = ($SSH_PUBKEY -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n") + "`n"
        [System.IO.File]::WriteAllText("$stage\authorized_keys", $akText, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "[ssh] staged authorized_keys from `$SSH_PUBKEY (key login)"
    } else {
        Write-Host "[ssh] `$SSH_PUBKEY not set -> password login only" -ForegroundColor DarkYellow
    }

    # === 8d) Stage EMS-SAC first-boot fallback (online FoD install) ===
    # setup-ems-sac.ps1 self-gates: it exits immediately if the FoD is already Installed (the
    # offline path in 5c succeeded). It only tries an online Windows-Update install when the
    # marker file ems-sac-online.flag is present, which we write only for EMS_SAC_SOURCE=online.
    # This keeps offline/air-gapped builds fully deterministic while still offering a one-touch
    # online path for users without a FoD ISO.
    Copy-Item (Join-Path $HERE "setup-ems-sac.ps1") "$stage\setup-ems-sac.ps1" -Force
    Write-Host "[ems-sac] staged setup-ems-sac.ps1 (first-boot FoD ensure)"
    if ($emsSacOnline) {
        [System.IO.File]::WriteAllText("$stage\ems-sac-online.flag", $EMS_SAC_CAP, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "[ems-sac] armed online first-boot FoD install (EMS_SAC_SOURCE=online)" -ForegroundColor Yellow
    }

    # === 8b) ReTrim so debloat/cleanup actually shrinks the image ===
    # Mirrors macOS's Optimize-Volume -ReTrim: unmaps the clusters freed above by debloat/ResetBase.
    # Otherwise, although that space is marked free in NTFS, the VHDX still holds the old data (non-zero),
    # and step 9 qemu-img convert would copy it into the qcow2 too -> no shrink.
    Write-Host "[shrink] Optimize-Volume -ReTrim on $W ..."
    try {
        Show-CommandLine "Optimize-Volume" @("-DriveLetter", $LETTER_WIN, "-ReTrim")
        Optimize-Volume -DriveLetter $LETTER_WIN -ReTrim -ErrorAction Stop
    } catch {
        Write-Host "  (ReTrim skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }

    # === 9) Detach VHDX -> convert to qcow2 ===
    Cleanup; $vhdAttached = $false; $isoMounted = $false
    Write-Host "[qcow2] converting -> $OUT_QCOW ..."
    # $COMPRESS adds -c with compression_type=zstd (zstd-compressed clusters, roughly half the size). DroidVM's
    # crosvm reads zstd clusters directly (its qcow2 backend gained zstd read support), so the image boots as-is;
    # plain -c (zlib) it can NOT read, so that form is never emitted. Still bootable in plain qemu. Default off.
    $convArgs = @("convert", "-p")
    if ($COMPRESS) { $convArgs += @("-c", "-o", "compression_type=zstd") }
    $convArgs += @("-O", "qcow2", $VHDX, $OUT_QCOW)
    Invoke-ExternalCommand -FilePath "qemu-img" -ArgumentList $convArgs -What "qemu-img convert"
    $sz = "{0:N1} GB" -f ((Get-Item $OUT_QCOW).Length / 1GB)
    Write-Host "Done  -> $OUT_QCOW ($sz)" -ForegroundColor Green

    # === 10) Optional: pack a ready-to-import .vmpkg (qcow2 + local VM config incl. SBSA console) ===
    if ($OUT_VMPKG) {
        Write-Host "[vmpkg] packing $OUT_VMPKG ..."
        $vmpkgComp = $VMPKG_COMPRESSION
        if ($COMPRESS) {
            Write-Host "[vmpkg] note: zstd-compressed qcow2 inside -> needs the crosvm with qcow2 zstd read support" -ForegroundColor DarkYellow
            # Compressing zstd clusters again buys ~1.7% (measured); auto picks none so an import is a plain copy.
            if ($vmpkgComp -eq "auto") { $vmpkgComp = "none" }
        }
        # Pure PowerShell + the built-in tar.exe (Windows 10 1803+): no python needed.
        & (Join-Path $ROOT "pack-vmpkg.ps1") -Qcow2 $OUT_QCOW -Config $VMS_JSON `
            -Out $OUT_VMPKG -Compression $vmpkgComp -Threads $VMPKG_THREADS
        Write-Host "[vmpkg] Done  -> $OUT_VMPKG" -ForegroundColor Green
    }
}
finally {
    Cleanup
    Show-CommandLine "Remove-Item" @("-Recurse", "-Force", $WORK, "-ErrorAction", "SilentlyContinue")
    Remove-Item -Recurse -Force $WORK -ErrorAction SilentlyContinue
}
