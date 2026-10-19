# User-approved deterministic startup-only round crop; preserve every RGB pixel.
param(
    [string]$Source = 'AppScope/resources/base/media/jim1_resized.png',
    [string]$Destination = 'entry/src/main/resources/base/media/start_icon_rounded.png'
)
$ErrorActionPreference = 'Stop'
$taskSource = [IO.Path]::GetFullPath($Source)
$taskDestination = [IO.Path]::GetFullPath($Destination)
if ($taskSource -eq $taskDestination) { throw 'Source must not be overwritten.' }
if (Test-Path -LiteralPath $taskDestination) { throw 'Destination already exists; refusing to overwrite.' }
if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($taskDestination)))) {
    throw 'Destination directory must already exist.'
}
$taskOriginalHash = (Get-FileHash -LiteralPath $taskSource -Algorithm SHA256).Hash
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;

public static class StartupRoundCrop {
    public static int[] Generate(string source, string destination) {
        using (var input = new Bitmap(source))
        using (var output = new Bitmap(input.Width, input.Height, PixelFormat.Format32bppArgb)) {
            double radius = Math.Min(input.Width, input.Height) * 0.22;
            int altered = 0;
            for (int y = 0; y < input.Height; y++) {
                for (int x = 0; x < input.Width; x++) {
                    Color c = input.GetPixel(x, y);
                    double cx = x < radius ? radius : input.Width - radius;
                    double cy = y < radius ? radius : input.Height - radius;
                    bool corner = (x < radius || x + 1 > input.Width - radius)
                        && (y < radius || y + 1 > input.Height - radius);
                    int covered = 64;
                    if (corner) {
                        covered = 0;
                        for (int sy = 0; sy < 8; sy++) {
                            for (int sx = 0; sx < 8; sx++) {
                                double dx = x + (sx + 0.5) / 8.0 - cx;
                                double dy = y + (sy + 0.5) / 8.0 - cy;
                                if (dx * dx + dy * dy <= radius * radius) covered++;
                            }
                        }
                    }
                    int alpha = (c.A * covered + 32) / 64;
                    if (alpha != c.A) altered++;
                    output.SetPixel(x, y, Color.FromArgb(alpha, c.R, c.G, c.B));
                }
            }
            output.Save(destination, ImageFormat.Png);
            using (var saved = new Bitmap(destination)) {
                for (int y = 0; y < input.Height; y++) {
                    for (int x = 0; x < input.Width; x++) {
                        Color a = input.GetPixel(x, y), b = saved.GetPixel(x, y);
                        if (a.R != b.R || a.G != b.G || a.B != b.B)
                            throw new Exception("RGB preservation failed.");
                        if ((x >= radius && x + 1 <= input.Width - radius
                            || y >= radius && y + 1 <= input.Height - radius) && a.A != b.A)
                            throw new Exception("Interior alpha preservation failed.");
                    }
                }
                if (saved.GetPixel(0, 0).A != 0 || saved.GetPixel(input.Width - 1, 0).A != 0
                    || saved.GetPixel(0, input.Height - 1).A != 0
                    || saved.GetPixel(input.Width - 1, input.Height - 1).A != 0)
                    throw new Exception("Corners are not transparent.");
            }
            return new int[] { input.Width, input.Height, altered };
        }
    }
}
'@
$taskResult = [StartupRoundCrop]::Generate($taskSource, $taskDestination)
$taskFinalHash = (Get-FileHash -LiteralPath $taskSource -Algorithm SHA256).Hash
if ($taskOriginalHash -ne $taskFinalHash) { throw 'Source image changed.' }
[ordered]@{
    width = $taskResult[0]
    height = $taskResult[1]
    alphaChangedPixels = $taskResult[2]
    radiusRatio = 0.22
    sourceUnchanged = $true
    rgbPreserved = $true
    transparentCorners = $true
    sourceSha256 = $taskOriginalHash
    destination = $taskDestination
} | ConvertTo-Json -Compress
