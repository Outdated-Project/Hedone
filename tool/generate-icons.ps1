# The SVG is the source of truth. Only its M/L/C/Z path subset is accepted.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
[xml]$svg = Get-Content -LiteralPath (Join-Path $root 'assets/brand.svg') -Raw
$backgroundColor = $svg.svg.rect.fill
$inkColor = $svg.svg.path.fill
$pathData = $svg.svg.path.d
if ($pathData -match '[^MLCZ\d.\s-]') { throw 'Unsupported SVG path syntax' }
$tokens = [regex]::Matches($pathData, '[MLCZ]|-?\d+(?:\.\d+)?') | ForEach-Object { $_.Value }
$glyph = [Drawing.Drawing2D.GraphicsPath]::new()
$point = [Drawing.PointF]::new(0, 0)
for ($i = 0; $i -lt $tokens.Count;) {
    $op = $tokens[$i++]
    switch ($op) {
        'M' {
            $point = [Drawing.PointF]::new([float]$tokens[$i++], [float]$tokens[$i++])
            $glyph.StartFigure()
        }
        'L' {
            $next = [Drawing.PointF]::new([float]$tokens[$i++], [float]$tokens[$i++])
            $glyph.AddLine($point, $next)
            $point = $next
        }
        'C' {
            $a = [Drawing.PointF]::new([float]$tokens[$i++], [float]$tokens[$i++])
            $b = [Drawing.PointF]::new([float]$tokens[$i++], [float]$tokens[$i++])
            $next = [Drawing.PointF]::new([float]$tokens[$i++], [float]$tokens[$i++])
            $glyph.AddBezier($point, $a, $b, $next)
            $point = $next
        }
        'Z' { $glyph.CloseFigure() }
        default { throw "Unsupported SVG command: $op" }
    }
}
function Render-Icon([int] $size, [string] $path, [bool] $rounded = $true) {
    $renderSize = [Math]::Max(512, $size)
    $bitmap = [Drawing.Bitmap]::new($renderSize, $renderSize)
    $g = [Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.ScaleTransform($renderSize / 108.0, $renderSize / 108.0)
    $background = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($backgroundColor))
    $ink = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($inkColor))
    $shape = [Drawing.Drawing2D.GraphicsPath]::new()
    try {
        if ($rounded) {
            $diameter = 2 * [float]$svg.svg.rect.rx
            $far = 108 - $diameter
            $shape.AddArc(0, 0, $diameter, $diameter, 180, 90)
            $shape.AddArc($far, 0, $diameter, $diameter, 270, 90)
            $shape.AddArc($far, $far, $diameter, $diameter, 0, 90)
            $shape.AddArc(0, $far, $diameter, $diameter, 90, 90)
            $shape.CloseFigure()
            $g.FillPath($background, $shape)
        } else { $g.FillRectangle($background, 0, 0, 108, 108) }
        $g.FillPath($ink, $glyph)
        $format = if ($rounded) { [Drawing.Imaging.PixelFormat]::Format32bppArgb } else { [Drawing.Imaging.PixelFormat]::Format24bppRgb }
        $output = [Drawing.Bitmap]::new($size, $size, $format)
        $resize = [Drawing.Graphics]::FromImage($output)
        try {
            $resize.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $resize.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $resize.DrawImage($bitmap, 0, 0, $size, $size)
            $output.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        } finally { $resize.Dispose(); $output.Dispose() }
    } finally {
        $shape.Dispose(); $ink.Dispose(); $background.Dispose(); $g.Dispose(); $bitmap.Dispose()
    }
}
try {
    Render-Icon 1024 (Join-Path $root 'assets/brand.png')
    foreach ($folder in @('android/app/src/main/res', 'ios/Runner/Assets.xcassets/AppIcon.appiconset', 'macos/Runner/Assets.xcassets/AppIcon.appiconset', 'web')) {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $folder) -Recurse -Filter '*.png') {
            if ($folder -like 'android*' -and $file.Name -ne 'ic_launcher.png') { continue }
            if ($folder -eq 'web' -and $file.Name -notmatch '^(favicon|Icon-.+)\.png$') { continue }
            $existing = [Drawing.Image]::FromFile($file.FullName)
            $size = $existing.Width
            $existing.Dispose()
            Render-Icon $size $file.FullName ($folder -notlike 'ios*' -and $file.Name -notlike '*maskable*')
        }
    }
    $encoding = [Text.UTF8Encoding]::new($false)
    $res = Join-Path $root 'android/app/src/main/res'
    foreach ($name in @('drawable', 'mipmap-anydpi-v26', 'mipmap-anydpi-v33')) {
        [IO.Directory]::CreateDirectory((Join-Path $res $name)) | Out-Null
    }
    $vector = '<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108"><group android:scaleX="0.9" android:scaleY="0.9" android:pivotX="54" android:pivotY="54"><path android:fillColor="{0}" android:pathData="{1}"/></group></vector>'
    [IO.File]::WriteAllText((Join-Path $res 'drawable/ic_launcher_foreground.xml'), ($vector -f $inkColor, $pathData), $encoding)
    [IO.File]::WriteAllText((Join-Path $res 'drawable/ic_launcher_monochrome.xml'), ($vector -f '#FFFFFF', $pathData), $encoding)
    $adaptive = '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android"><background android:drawable="@color/ic_launcher_background"/><foreground android:drawable="@drawable/ic_launcher_foreground"/>{0}</adaptive-icon>'
    [IO.File]::WriteAllText((Join-Path $res 'values/ic_launcher_background.xml'), ('<resources><color name="ic_launcher_background">{0}</color></resources>' -f $backgroundColor), $encoding)
    [IO.File]::WriteAllText((Join-Path $res 'mipmap-anydpi-v26/ic_launcher.xml'), ($adaptive -f ''), $encoding)
    [IO.File]::WriteAllText((Join-Path $res 'mipmap-anydpi-v33/ic_launcher.xml'), ($adaptive -f '<monochrome android:drawable="@drawable/ic_launcher_monochrome"/>'), $encoding)
    $frames = @()
    foreach ($size in @(16, 24, 32, 48, 64, 128, 256)) {
        $path = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName() + '.png')
        try {
            Render-Icon $size $path
            $frames += ,@($size, [IO.File]::ReadAllBytes($path))
        } finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
    }
    $writer = [IO.BinaryWriter]::new([IO.File]::Create((Join-Path $root 'windows/runner/resources/app_icon.ico')))
    try {
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
    } finally { $writer.Dispose() }
} finally { $glyph.Dispose() }
