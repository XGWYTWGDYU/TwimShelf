// The picture a model is asked about, the same on every device: upright, at most 896 on its long
// side, at least 112 on its short side, padded (black) to no more than 4:1, JPEG quality 80.
// Windows' own codecs do the work (WIC through Windows.Graphics.Imaging); HEIC and AVIF go
// through the core first, videos through their shell thumbnail.
using System.Runtime.InteropServices.WindowsRuntime;
using TwimShelf.Core;
using TwimShelf.Services;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.FileProperties;
using Windows.Storage.Streams;

namespace TwimShelf.AI;

public static class TaggingImage
{
    public static async Task<byte[]?> Prepare(MediaRef media)
    {
        try
        {
            if (media.Kind == "video")
            {
                // StorageFile refuses a path with both separators, as the core makes them (…\lib\blobs/ab/…)
                var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(media.Path));
                using var thumb = await file.GetThumbnailAsync(ThumbnailMode.SingleItem, 896, ThumbnailOptions.ResizeThumbnail);
                if (thumb == null) return null;
                return await Encode(thumb);
            }
            var path = await Thumbnails.Displayable(media.Path, 896);
            var f = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
            using var s = await f.OpenReadAsync();
            return await Encode(s);
        }
        catch (Exception e) { Diagnostics.Log("tagging image: " + e.GetType().Name + ": " + e.Message + "\n" + e.StackTrace); return null; }
    }

    static async Task<byte[]?> Encode(IRandomAccessStream input)
    {
        var decoder = await BitmapDecoder.CreateAsync(input);
        // upright first (EXIF orientation applied), then the sizes
        var upright = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, new BitmapTransform(), ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
        double w = upright.PixelWidth, h = upright.PixelHeight;
        if (w <= 0 || h <= 0) return null;
        var fit = Math.Min(1.0, 896 / Math.Max(w, h));
        w *= fit; h *= fit;
        var shortSide = Math.Min(w, h);
        var longSide = Math.Max(w, h);
        var grow = Math.Clamp(112 / shortSide, 1.0, 896 / longSide < 1 ? 1.0 : 896 / longSide);
        uint sw = (uint)Math.Max(1, Math.Round(w * grow)), sh = (uint)Math.Max(1, Math.Round(h * grow));

        var scaled = await Resize(upright, sw, sh);
        uint cw = Math.Max(sw, (uint)Math.Ceiling(sh / 4.0)), ch = Math.Max(sh, (uint)Math.Ceiling(sw / 4.0));
        var canvas = cw == sw && ch == sh ? scaled : Pad(scaled, cw, ch);

        using var output = new InMemoryRandomAccessStream();
        var props = new BitmapPropertySet { ["ImageQuality"] = new BitmapTypedValue(0.8, Windows.Foundation.PropertyType.Single) };
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, output, props);
        encoder.SetSoftwareBitmap(canvas);
        await encoder.FlushAsync();
        var bytes = new byte[output.Size];
        output.Seek(0);
        await output.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
        return bytes;
    }

    static async Task<SoftwareBitmap> Resize(SoftwareBitmap source, uint w, uint h)
    {
        if (source.PixelWidth == w && source.PixelHeight == h) return source;
        using var tmp = new InMemoryRandomAccessStream();
        var enc = await BitmapEncoder.CreateAsync(BitmapEncoder.BmpEncoderId, tmp);
        enc.SetSoftwareBitmap(source);
        enc.BitmapTransform.ScaledWidth = w;
        enc.BitmapTransform.ScaledHeight = h;
        enc.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Fant;
        await enc.FlushAsync();
        tmp.Seek(0);
        var dec = await BitmapDecoder.CreateAsync(tmp);
        return await dec.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
    }

    static SoftwareBitmap Pad(SoftwareBitmap source, uint w, uint h)
    {
        var src = new byte[4 * source.PixelWidth * source.PixelHeight];
        source.CopyToBuffer(src.AsBuffer());
        var dst = new byte[4 * w * h];
        for (var i = 3; i < dst.Length; i += 4) dst[i] = 255;
        var ox = (int)Math.Round((w - source.PixelWidth) / 2.0);
        var oy = (int)Math.Round((h - source.PixelHeight) / 2.0);
        for (var y = 0; y < source.PixelHeight; y++)
            System.Buffer.BlockCopy(src, y * source.PixelWidth * 4, dst, ((y + oy) * (int)w + ox) * 4, source.PixelWidth * 4);
        var bmp = new SoftwareBitmap(BitmapPixelFormat.Bgra8, (int)w, (int)h, BitmapAlphaMode.Ignore);
        bmp.CopyFromBuffer(dst.AsBuffer());
        return bmp;
    }

    /// A small grey picture (the test of an external service).
    public static async Task<byte[]> GrayJpeg()
    {
        var px = new byte[64 * 64 * 4];
        for (var i = 0; i < px.Length; i += 4) { px[i] = px[i + 1] = px[i + 2] = 128; px[i + 3] = 255; }
        var bmp = new SoftwareBitmap(BitmapPixelFormat.Bgra8, 64, 64, BitmapAlphaMode.Ignore);
        bmp.CopyFromBuffer(px.AsBuffer());
        using var output = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, output);
        encoder.SetSoftwareBitmap(bmp);
        await encoder.FlushAsync();
        var bytes = new byte[output.Size];
        output.Seek(0);
        await output.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
        return bytes;
    }
}
