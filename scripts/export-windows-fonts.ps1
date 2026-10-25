<#
.SYNOPSIS
    Copies the fonts from a Windows install into a folder and a zip, for use on Linux.

.DESCRIPTION
    Reads the system font folder (C:\Windows\Fonts), the per-user font folder
    (%LOCALAPPDATA%\Microsoft\Windows\Fonts) and Office's cloud font cache
    (%LOCALAPPDATA%\Microsoft\FontCache\4\CloudFonts). None needs admin rights.

    Fonts Office installs locally (Century Gothic, Garamond, Gill Sans MT...) land in the
    system folder, so they're picked up there. Cloud fonts (Aptos and the like) are only
    downloaded once a document uses them, and Office stores them as numbered files in one
    folder per family; they're copied as "<Family>-<number>.ttf" so the names don't collide.

    With -CommonOnly, copies just the usual Microsoft and Office families (Segoe, Calibri,
    Consolas, Arial, Times, Aptos...).

    On Linux afterwards:
        unzip WindowsFonts.zip -d ~/.local/share/fonts/WindowsFonts && fc-cache -f

    The fonts are licensed with Windows and Office: keep them on your own machines, don't
    redistribute.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\export-windows-fonts.ps1

.EXAMPLE
    .\export-windows-fonts.ps1 -Destination D:\fonts -CommonOnly -IncludeBitmap
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'WindowsFonts'),
    [switch]$CommonOnly,
    [switch]$IncludeBitmap
)

$ErrorActionPreference = 'Stop'

$sources = @(
    (Join-Path $env:WINDIR 'Fonts'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts')
) | Where-Object { Test-Path -LiteralPath $_ }

$cloudRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\FontCache\4\CloudFonts'
$hasCloud = Test-Path -LiteralPath $cloudRoot

if (-not $sources -and -not $hasCloud) {
    throw 'No Windows font folder found; run this on a Windows install.'
}

$extensions = @('.ttf', '.ttc', '.otf')
if ($IncludeBitmap) { $extensions += '.fon' }

# Matched against the file name, or for cloud fonts against the family folder name.
$common = @(
    'arial*', 'times*', 'cour*', 'verdana*', 'tahoma*', 'georgia*', 'trebuc*', 'comic*',
    'impact*', 'calibri*', 'cambria*', 'candara*', 'consola*', 'constan*', 'corbel*',
    'segoe*', 'segui*', 'webdings*', 'wingding*', 'symbol*',
    'msyh*', 'yugoth*', 'malgun*',
    # Installed by Office: Century Gothic, Century, Garamond, Book Antiqua, Bookman Old Style,
    # Gill Sans MT, Tw Cen MT, Rockwell, Franklin Gothic.
    'gothic*', 'century*', 'gara*', 'bkant*', 'bookos*', 'gil*',
    'tcm*', 'tcb*', 'tccm*', 'rock*', 'fra*',
    # Office cloud fonts (family folder names).
    'aptos*', 'grandview*', 'seaford*', 'skeena*', 'tenorite*', 'bierstadt*'
)

$fonts = @()

if ($sources) {
    $fonts += Get-ChildItem -LiteralPath $sources -File -ErrorAction SilentlyContinue |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
        ForEach-Object { [pscustomobject]@{ File = $_; Name = $_.Name; Key = $_.Name; Cloud = $false } }
}

if ($hasCloud) {
    $fonts += Get-ChildItem -LiteralPath $cloudRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $family = $_.Name
            $familyDir = $_.FullName
            Get-ChildItem -LiteralPath $familyDir -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
                ForEach-Object {
                    # Keep any subfolder in the name so same-numbered files in different subfolders don't collide.
                    $relative = $_.FullName.Substring($familyDir.Length).TrimStart('\', '/')
                    $name = "$family-$relative" -replace '[^\w.-]', '_'
                    [pscustomobject]@{ File = $_; Name = $name; Key = $family; Cloud = $true }
                }
        }
}

if ($CommonOnly) {
    $fonts = $fonts | Where-Object {
        $key = $_.Key
        @($common | Where-Object { $key -like $_ }).Count -gt 0
    }
}

$fonts = @($fonts)
if ($fonts.Count -eq 0) {
    $searched = @($sources) + @($cloudRoot | Where-Object { $hasCloud })
    throw "No font files found in: $($searched -join ', ')"
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null

# A per-user font can share a file name with a system one; the later source (per-user) wins.
foreach ($font in $fonts) {
    Copy-Item -LiteralPath $font.File.FullName -Destination (Join-Path $Destination $font.Name) -Force
}

# Zip only this run's files, so leftovers from an earlier run in $Destination aren't swept in.
$copied = @($fonts | ForEach-Object { Join-Path $Destination $_.Name } | Sort-Object -Unique)

$zip = "$Destination.zip"
Compress-Archive -LiteralPath $copied -DestinationPath $zip -Force

$cloudCount = @($fonts | Where-Object Cloud | ForEach-Object Name | Sort-Object -Unique).Count
Write-Output "Copied $($copied.Count) font files to $Destination ($cloudCount from Office cloud fonts)"
Write-Output "Archive: $zip"
