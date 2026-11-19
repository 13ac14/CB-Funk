$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-RadioIcon([int]$Size) {
    $bitmap = [System.Drawing.Bitmap]::new(
        $Size,
        $Size,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $scale = $Size / 1024.0
    $graphics.ScaleTransform([single]$scale, [single]$scale)

    $shape = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $radius = 190
    $shape.AddArc(0, 0, $radius, $radius, 180, 90)
    $shape.AddArc(1024 - $radius, 0, $radius, $radius, 270, 90)
    $shape.AddArc(1024 - $radius, 1024 - $radius, $radius, $radius, 0, 90)
    $shape.AddArc(0, 1024 - $radius, $radius, $radius, 90, 90)
    $shape.CloseFigure()

    $background = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        [System.Drawing.Rectangle]::new(0, 0, 1024, 1024),
        [System.Drawing.Color]::FromArgb(225, 28, 48),
        [System.Drawing.Color]::FromArgb(126, 14, 33),
        [single]90
    )
    $graphics.FillPath($background, $shape)

    $white = [System.Drawing.Color]::FromArgb(255, 255, 250, 244)
    $wavePen = [System.Drawing.Pen]::new($white, 24)
    $wavePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $wavePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawArc($wavePen, 300, 120, 424, 380, 210, 120)
    $graphics.DrawArc($wavePen, 205, 55, 614, 520, 210, 120)

    $mastPen = [System.Drawing.Pen]::new($white, 28)
    $mastPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $mastPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawLine($mastPen, 512, 270, 512, 400)
    $graphics.FillEllipse([System.Drawing.SolidBrush]::new($white), 493, 225, 38, 38)

    $font = [System.Drawing.Font]::new(
        'Arial',
        365,
        [System.Drawing.FontStyle]::Bold,
        [System.Drawing.GraphicsUnit]::Pixel
    )
    $format = [System.Drawing.StringFormat]::new()
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $graphics.DrawString(
        '11',
        $font,
        [System.Drawing.SolidBrush]::new($white),
        [System.Drawing.RectangleF]::new(80, 475, 864, 430),
        $format
    )

    $graphics.Dispose()
    $shape.Dispose()
    $background.Dispose()
    $wavePen.Dispose()
    $mastPen.Dispose()
    $font.Dispose()
    $format.Dispose()
    return $bitmap
}

$root = Split-Path -Parent $PSScriptRoot
$base = New-RadioIcon 1024
$base.Save((Join-Path $root 'assets\icons\app_icon_1024.png'), [System.Drawing.Imaging.ImageFormat]::Png)

$iconSizes = @{
    'mipmap-mdpi' = 48
    'mipmap-hdpi' = 72
    'mipmap-xhdpi' = 96
    'mipmap-xxhdpi' = 144
    'mipmap-xxxhdpi' = 192
}
foreach ($entry in $iconSizes.GetEnumerator()) {
    foreach ($directory in @(
        (Join-Path $root "assets\icons\android\$($entry.Key)"),
        (Join-Path $root "android\app\src\main\res\$($entry.Key)")
    )) {
        $small = [System.Drawing.Bitmap]::new($entry.Value, $entry.Value)
        $graphics = [System.Drawing.Graphics]::FromImage($small)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($base, 0, 0, $entry.Value, $entry.Value)
        $small.Save((Join-Path $directory 'ic_launcher.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $small.Dispose()
    }
}

$icon = New-RadioIcon 256
foreach ($path in @(
    (Join-Path $root 'assets\icons\app_icon.ico'),
    (Join-Path $root 'windows\runner\resources\app_icon.ico')
)) {
    $stream = [System.IO.File]::Create($path)
    [System.Drawing.Icon]::FromHandle($icon.GetHicon()).Save($stream)
    $stream.Dispose()
}

$icon.Dispose()
$base.Dispose()