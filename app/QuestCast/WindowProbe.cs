using System.Runtime.InteropServices;

namespace QuestCast;

/// <summary>
/// Grabs the current frame of a video window as a square grayscale image, so the
/// horizon estimator can measure what the operator actually sees.
///
/// PrintWindow is used instead of a screen copy because the cast window sits under
/// other windows most of the time, and because a screen copy of a DWM-composed area
/// hides layered windows. PW_CLIENTONLY keeps the title bar out of the picture.
/// </summary>
internal static class WindowProbe
{
    private const uint PW_CLIENTONLY = 1;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string? cls, string title);

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);

    [DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr obj);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER header, uint usage,
        out IntPtr bits, IntPtr section, uint offset);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    private const uint BI_RGB = 0;
    private const uint DIB_RGB_COLORS = 0;

    /// <summary>
    /// Returns a <paramref name="outSize"/> squared grayscale image of the window's
    /// content, or null when the window is missing or refused to draw.
    /// The video is pillarboxed inside the client area, so the square in the middle
    /// is picked: otherwise the black bars would add vertical edges and drag the
    /// estimate towards zero.
    /// </summary>
    public static byte[]? GrabSquare(string title, int outSize)
    {
        var hwnd = FindWindow(null, title);
        if (hwnd == IntPtr.Zero) return null;
        if (!GetClientRect(hwnd, out var rc)) return null;
        var width = rc.Right - rc.Left;
        var height = rc.Bottom - rc.Top;
        if (width < 64 || height < 64) return null;

        var screenDc = GetDC(hwnd);
        if (screenDc == IntPtr.Zero) return null;
        var memDc = CreateCompatibleDC(screenDc);
        IntPtr bitmap = IntPtr.Zero;
        IntPtr old = IntPtr.Zero;
        try
        {
            var header = new BITMAPINFOHEADER
            {
                biSize = (uint)Marshal.SizeOf<BITMAPINFOHEADER>(),
                biWidth = width,
                biHeight = -height,           // top-down rows
                biPlanes = 1,
                biBitCount = 32,
                biCompression = BI_RGB
            };
            bitmap = CreateDIBSection(memDc, ref header, DIB_RGB_COLORS, out var bits, IntPtr.Zero, 0);
            if (bitmap == IntPtr.Zero || bits == IntPtr.Zero) return null;
            old = SelectObject(memDc, bitmap);
            if (!PrintWindow(hwnd, memDc, PW_CLIENTONLY)) return null;

            var stride = width * 4;
            var pixels = new byte[stride * height];
            Marshal.Copy(bits, pixels, 0, pixels.Length);

            var side = Math.Min(width, height);
            var x0 = (width - side) / 2;
            var y0 = (height - side) / 2;
            var gray = new byte[outSize * outSize];
            var step = (double)side / outSize;
            for (var oy = 0; oy < outSize; oy++)
            {
                var sy0 = y0 + (int)(oy * step);
                var sy1 = Math.Min(y0 + side, y0 + (int)((oy + 1) * step));
                if (sy1 <= sy0) sy1 = sy0 + 1;
                for (var ox = 0; ox < outSize; ox++)
                {
                    var sx0 = x0 + (int)(ox * step);
                    var sx1 = Math.Min(x0 + side, x0 + (int)((ox + 1) * step));
                    if (sx1 <= sx0) sx1 = sx0 + 1;
                    long sum = 0;
                    var n = 0;
                    for (var y = sy0; y < sy1; y++)
                    {
                        var row = y * stride;
                        for (var x = sx0; x < sx1; x++)
                        {
                            var i = row + x * 4;
                            // BT.601 luma, BGRA order from GDI
                            sum += (pixels[i + 2] * 299 + pixels[i + 1] * 587 + pixels[i] * 114) / 1000;
                            n++;
                        }
                    }
                    gray[oy * outSize + ox] = (byte)(n > 0 ? sum / n : 0);
                }
            }
            return gray;
        }
        finally
        {
            if (old != IntPtr.Zero) SelectObject(memDc, old);
            if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
            DeleteDC(memDc);
            ReleaseDC(hwnd, screenDc);
        }
    }
}
