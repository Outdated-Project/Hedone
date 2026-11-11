# Reproducible vector-to-raster launcher assets. No image service or extra SDK.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Render-Icon([int] $size, [string] $path, [bool] $rounded = $true) {
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    $g = [Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.ScaleTransform($size / 108.0, $size / 108.0)
    $background = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#E5EACF'))
    $ink = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#465720'))
    $shape = [Drawing.Drawing2D.GraphicsPath]::new()
    if ($rounded) {
        $shape.AddArc(0, 0, 52, 52, 180, 90)
        $shape.AddArc(56, 0, 52, 52, 270, 90)
        $shape.AddArc(56, 56, 52, 52, 0, 90)
        $shape.AddArc(0, 56, 52, 52, 90, 90)
        $shape.CloseFigure()
        $g.FillPath($background, $shape)
    } else { $g.FillRectangle($background, 0, 0, 108, 108) }
    $pen = [Drawing.Pen]::new($ink, 9)
    $pen.StartCap = $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($pen, 35, 32, 35, 76)
    $g.DrawLine($pen, 70, 44, 70, 76)
    $g.DrawBezier($pen, 35, 55, 45, 44, 60, 44, 70, 55)
    $pen.Width = 4
    $g.DrawBezier($pen, 44, 69, 50, 76, 56, 76, 62, 69)
    $star = [Drawing.Drawing2D.GraphicsPath]::new()
    $star.AddBezier(73,22,75,31,75,31,84,33)
    $star.AddBezier(84,33,75,35,75,35,73,44)
    $star.AddBezier(73,44,71,35,71,35,62,33)
    $star.AddBezier(62,33,71,31,71,31,73,22)
    $star.CloseFigure()
    $g.FillPath($ink, $star)
    $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $star.Dispose(); $pen.Dispose(); $shape.Dispose(); $ink.Dispose(); $background.Dispose(); $g.Dispose(); $bitmap.Dispose()
}
Render-Icon 1024 (Join-Path $root 'assets/brand.png')
foreach ($folder in @('android/app/src/main/res', 'ios/Runner/Assets.xcassets/AppIcon.appiconset', 'macos/Runner/Assets.xcassets/AppIcon.appiconset', 'web')) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $folder) -Recurse -Filter '*.png') {
        if ($folder -like 'android*' -and $file.Name -ne 'ic_launcher.png') { continue }
        $existing = [Drawing.Image]::FromFile($file.FullName)
        $size = $existing.Width
        $existing.Dispose()
        $rounded = $folder -notlike 'ios*' -and $file.Name -notlike '*maskable*'
        Render-Icon $size $file.FullName $rounded
    }
}
$frames = @()
foreach ($size in @(16, 24, 32, 48, 64, 128, 256)) {
    $path = Join-Path ([IO.Path]::GetTempPath()) "hedone-icon-$size.png"
    Render-Icon $size $path
    $frames += ,@($size, [IO.File]::ReadAllBytes($path))
    Remove-Item -LiteralPath $path
}
$stream = [IO.File]::Create((Join-Path $root 'windows/runner/resources/app_icon.ico'))
$writer = [IO.BinaryWriter]::new($stream)
$writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($frame in $frames) {
    $dimension = if ($frame[0] -eq 256) { 0 } else { $frame[0] }
    $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
    $writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]32)
    $writer.Write([UInt32]$frame[1].Length); $writer.Write([UInt32]$offset)
    $offset += $frame[1].Length
}
foreach ($frame in $frames) { $writer.Write([byte[]]$frame[1]) }
$writer.Dispose()
