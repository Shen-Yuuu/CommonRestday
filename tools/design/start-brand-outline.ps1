# Regenerate vector wordmark outlines; stdout is JSON, no files are written.
Add-Type -AssemblyName System.Drawing
$taskCulture = [Globalization.CultureInfo]::InvariantCulture
function Coordinate($point) {
    $point.X.ToString('0.###', $taskCulture) + ' ' + $point.Y.ToString('0.###', $taskCulture)
}
function Outline($label, $familyName, $size, $style, $top) {
    $family = [Drawing.FontFamily]::new($familyName)
    $outline = [Drawing.Drawing2D.GraphicsPath]::new()
    $format = [Drawing.StringFormat]::GenericTypographic.Clone()
    $matrix = [Drawing.Drawing2D.Matrix]::new()
    try {
        $outline.AddString($label, $family, [int]$style, [single]$size,
            [Drawing.PointF]::new(0, 0), $format)
        $bounds = $outline.GetBounds()
        $matrix.Translate([single]((320 - $bounds.Width) / 2 - $bounds.X),
            [single]($top - $bounds.Y))
        $outline.Transform($matrix)
        $points = $outline.PathPoints
        $types = $outline.PathTypes
        $commands = [Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $points.Length; $i++) {
            switch ($types[$i] -band 7) {
                0 { $commands.Add('M' + (Coordinate $points[$i])) }
                1 { $commands.Add('L' + (Coordinate $points[$i])) }
                3 {
                    $commands.Add('C' + (Coordinate $points[$i]) + ' ' +
                        (Coordinate $points[$i + 1]) + ' ' + (Coordinate $points[$i + 2]))
                    $i += 2
                }
                default { throw 'Unsupported outline segment' }
            }
            if (($types[$i] -band 128) -ne 0) { $commands.Add('Z') }
        }
        $commands -join ' '
    } finally {
        $matrix.Dispose()
        $format.Dispose()
        $outline.Dispose()
        $family.Dispose()
    }
}
$chineseLabel = [string][char]0x4E24 + [char]0x4EBA + [char]0x4EFD
[ordered]@{
    ChinesePath = Outline $chineseLabel 'Microsoft YaHei' 52 ([Drawing.FontStyle]::Bold) 18
    EnglishPath = Outline 'ForTwo' 'Segoe UI' 26 ([Drawing.FontStyle]::Regular) 83
} | ConvertTo-Json -Compress
