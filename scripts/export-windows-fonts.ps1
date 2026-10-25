<#
.SYNOPSIS
    Copies the fonts from a Windows install into a folder and a zip, for use on Linux.

.DESCRIPTION
    Reads the system font folder (C:\Windows\Fonts) and the per-user font folder
    (%LOCALAPPDATA%\Microsoft\Windows\Fonts). Neither needs admin rights. With -CommonOnly,
    copies just the usual Microsoft families (Segoe, Calibri, Consolas, Arial, Times...).

    On Linux afterwards:
        unzip WindowsFonts.zip -d ~/.local/share/fonts/WindowsFonts && fc-cache -f

    The fonts are licensed with Windows: keep them on your own machines, don't redistribute.

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

if (-not $sources) {
    throw 'No Windows font folder found; run this on a Windows install.'
}

$extensions = @('.ttf', '.ttc', '.otf')
if ($IncludeBitmap) { $extensions += '.fon' }

$common = @(
    'arial*', 'times*', 'cour*', 'verdana*', 'tahoma*', 'georgia*', 'trebuc*', 'comic*',
    'impact*', 'calibri*', 'cambria*', 'candara*', 'consola*', 'constan*', 'corbel*',
    'segoe*', 'segui*', 'webdings*', 'wingding*', 'symbol*',
    'msyh*', 'yugoth*', 'malgun*'
)

New-Item -ItemType Directory -Force -Path $Destination | Out-Null

$fonts = Get-ChildItem -LiteralPath $sources -File -ErrorAction SilentlyContinue |
    Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() }

if ($CommonOnly) {
    $fonts = $fonts | Where-Object {
        $name = $_.Name
        @($common | Where-Object { $name -like $_ }).Count -gt 0
    }
}

$fonts = @($fonts)
if ($fonts.Count -eq 0) {
    throw "No font files found in: $($sources -join ', ')"
}

# A per-user font can share a file name with a system one; the later source (per-user) wins.
$fonts | Copy-Item -Destination $Destination -Force

# Zip only this run's files, so leftovers from an earlier run in $Destination aren't swept in.
$copied = @($fonts | ForEach-Object { Join-Path $Destination $_.Name } | Sort-Object -Unique)

$zip = "$Destination.zip"
Compress-Archive -LiteralPath $copied -DestinationPath $zip -Force

Write-Output "Copied $($copied.Count) font files to $Destination"
Write-Output "Archive: $zip"
