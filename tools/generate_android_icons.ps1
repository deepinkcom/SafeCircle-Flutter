param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$sourcePath = Join-Path $RepoRoot 'assets/branding/neon_shield_community_original.png'
$resRoot = Join-Path $RepoRoot 'android/app/src/main/res'
$source = [System.Drawing.Bitmap]::new($sourcePath)

# Trim transparent pixels only. Never crop the shield, people, bell or orbit.
$left = $source.Width
$top = $source.Height
$right = -1
$bottom = -1
for ($y = 0; $y -lt $source.Height; $y++) {
    for ($x = 0; $x -lt $source.Width; $x++) {
        if ($source.GetPixel($x, $y).A -gt 0) {
            $left = [Math]::Min($left, $x)
            $top = [Math]::Min($top, $y)
            $right = [Math]::Max($right, $x)
            $bottom = [Math]::Max($bottom, $y)
        }
    }
}
if ($right -lt 0) { throw 'Source image is entirely transparent.' }
$crop = [System.Drawing.Rectangle]::new($left, $top, $right - $left + 1, $bottom - $top + 1)
$navy = [System.Drawing.ColorTranslator]::FromHtml('#070D35')

function Write-Icon([string]$Path, [int]$Size, [double]$ArtworkFraction, [bool]$Opaque,
    [System.Drawing.Bitmap]$Artwork = $source, [System.Drawing.Rectangle]$Bounds = $crop) {
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        if ($Opaque) { $graphics.Clear($navy) }
        else { $graphics.Clear([System.Drawing.Color]::Transparent) }
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $scale = $Size * $ArtworkFraction / [Math]::Max($Bounds.Width, $Bounds.Height)
        $width = [int][Math]::Round($Bounds.Width * $scale)
        $height = [int][Math]::Round($Bounds.Height * $scale)
        $dest = [System.Drawing.Rectangle]::new([int][Math]::Floor(($Size - $width) / 2), [int][Math]::Floor(($Size - $height) / 2), $width, $height)
        $graphics.DrawImage($Artwork, $dest, $Bounds, [System.Drawing.GraphicsUnit]::Pixel)
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $graphics.Dispose(); $bitmap.Dispose() }
}

try {
    $densities = [ordered]@{ mdpi = 1; hdpi = 1.5; xhdpi = 2; xxhdpi = 3; xxxhdpi = 4 }
    foreach ($entry in $densities.GetEnumerator()) {
        $dir = Join-Path $resRoot ('mipmap-' + $entry.Key)
        Write-Icon (Join-Path $dir 'ic_launcher.png') ([int](48 * $entry.Value)) 0.92 $true
        # 108dp adaptive layer; the full tile is 66dp wide. Its central shield,
        # people and bell fit inside the safe circle; decorative corners may be masked.
        Write-Icon (Join-Path $dir 'ic_launcher_foreground.png') ([int](108 * $entry.Value)) (66.0 / 108) $false
    }
    $roundPath = Join-Path $RepoRoot 'assets/branding/neon_guardian_shield_original.png'
    $roundSource = [System.Drawing.Bitmap]::new($roundPath)
    try {
        # Preserve the full circular artwork and its rim. Do not crop stray glow.
        $roundBounds = [System.Drawing.Rectangle]::new(0, 0, $roundSource.Width, $roundSource.Height)
        foreach ($entry in $densities.GetEnumerator()) {
            $dir = Join-Path $resRoot ('mipmap-' + $entry.Key)
            Write-Icon (Join-Path $dir 'ic_launcher_round.png') ([int](48 * $entry.Value)) 0.92 $false $roundSource $roundBounds
            Write-Icon (Join-Path $dir 'ic_launcher_round_foreground.png') ([int](108 * $entry.Value)) (66.0 / 108) $false $roundSource $roundBounds
        }
    }
    finally { $roundSource.Dispose() }
    Write-Output "Generated square and round launcher resources for five densities. Square transparent-only crop: $crop"
}
finally { $source.Dispose() }
