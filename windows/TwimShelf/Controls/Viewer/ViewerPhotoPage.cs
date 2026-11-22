// One zoomable photo page of the unified viewer's horizontal strip (matching MacViewerPage,
// Web PhotoPage.tsx, and Flutter _PhotoPage):
//  * Shows the card's decoded preview or the grid's square thumbnail on Frame 0 (zero blank flash)
//    while the full-resolution image loads smoothly on top.
//  * Smooth 1×–8× zoom anchored under the pointer (Ctrl+wheel, touchpad pinch, touchscreen pinch,
//    Ctrl +/-, or animated 1× <-> 2.5× double-click/double-tap), plus click-drag pan while zoomed.
//  * Zero ScrollViewer conflict when unzoomed, so horizontal strip swipes and interactive
//    drag-to-dismiss work seamlessly.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TwimShelf.Core;
using TwimShelf.Services;
using Windows.Foundation;

namespace TwimShelf.Controls.ViewerEngine;

public sealed partial class ViewerPhotoPage : Grid
{
    public FeedItem Item { get; }
    public event Action<bool>? ZoomChanged;
    public event Action? PreviewReady;
    public bool IsPreviewReady { get; private set; }

    readonly Grid _frame = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        RenderTransformOrigin = new Point(0.5, 0.5),
    };
    readonly CompositeTransform _transform = new();
    readonly Image _preview = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        IsHitTestVisible = false,
    };
    readonly Image _full = new()
    {
        Stretch = Stretch.Uniform,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Opacity = 0,
        IsHitTestVisible = false,
    };

    readonly bool _cropSquarePreview;
    CancellationTokenSource? _loading;
    double _natW, _natH;
    double _viewW, _viewH;
    double _baseW, _baseH;
    PhotoView _view = PhotoView.Identity;
    bool _wasZoomed;
    bool _fullLoaded;

    // Animated double-click / reset zoom
    PhotoView _animFrom, _animTo;
    double _animStart;
    bool _animating;
    const double ZoomAnimDuration = 0.24;

    public bool IsZoomed => _view.IsZoomed;
    public bool IsAnimating => _animating;
    public double CurrentScale => _view.Scale;

    public ViewerPhotoPage(FeedItem item, ImageSource? previewImage = null, string? squarePreviewPath = null, bool cropSquarePreview = false)
    {
        Item = item;
        _cropSquarePreview = cropSquarePreview && previewImage == null && !string.IsNullOrEmpty(squarePreviewPath);
        _natW = item.Width > 0 ? item.Width : 0;
        _natH = item.Height > 0 ? item.Height : 0;

        IsHitTestVisible = false;
        _frame.RenderTransform = _transform;
        _frame.Children.Add(_preview);
        _frame.Children.Add(_full);
        Children.Add(_frame);

        if (previewImage != null)
        {
            _preview.Stretch = Stretch.Uniform;
            _preview.Source = previewImage;
            IsPreviewReady = true;
            if (previewImage is BitmapImage bi && bi.PixelWidth > 0 && bi.PixelHeight > 0 && (_natW <= 0 || _natH <= 0))
            {
                _natW = bi.PixelWidth;
                _natH = bi.PixelHeight;
            }
        }
        else if (!string.IsNullOrEmpty(squarePreviewPath) && File.Exists(squarePreviewPath))
        {
            _preview.Stretch = _cropSquarePreview ? Stretch.Fill : Stretch.Uniform;
            try
            {
                var pBmp = new BitmapImage();
                pBmp.ImageOpened += (_, _) => MarkPreviewReady();
                pBmp.ImageFailed += (_, _) => MarkPreviewReady();
                pBmp.UriSource = new Uri(squarePreviewPath);
                _preview.Source = pBmp;
            }
            catch { MarkPreviewReady(); }
        }

        SizeChanged += (_, e) => UpdateLayoutSize(e.NewSize.Width, e.NewSize.Height);
        _ = LoadFullAsync();
    }

    async Task LoadFullAsync()
    {
        _loading?.Cancel();
        var cancel = _loading = new CancellationTokenSource();
        var ct = cancel.Token;
        string path;
        try { path = await Thumbnails.Displayable(Item.Path, 8192); }
        catch { return; }
        if (ct.IsCancellationRequested) return;

        var bmp = new BitmapImage();
        bmp.ImageOpened += (_, _) =>
        {
            if (ct.IsCancellationRequested) return;
            if (bmp.PixelWidth > 0 && bmp.PixelHeight > 0)
            {
                _natW = bmp.PixelWidth;
                _natH = bmp.PixelHeight;
                UpdateLayoutSize(_viewW, _viewH);
            }
            _fullLoaded = true;
            _full.Opacity = 1;
            _preview.Visibility = Visibility.Collapsed;
            MarkPreviewReady();
        };
        bmp.ImageFailed += (_, _) => MarkPreviewReady();
        try
        {
            bmp.UriSource = new Uri(path);
            _full.Source = bmp;
        }
        catch { MarkPreviewReady(); }
    }

    void MarkPreviewReady()
    {
        if (IsPreviewReady) return;
        IsPreviewReady = true;
        PreviewReady?.Invoke();
    }

    public void UpdateLayoutSize(double w, double h)
    {
        if (w <= 0 || h <= 0) return;
        _viewW = w;
        _viewH = h;
        var fitted = FittedRect(new Rect(0, 0, w, h));
        _baseW = Math.Max(1, fitted.Width);
        _baseH = Math.Max(1, fitted.Height);
        _frame.Width = _baseW;
        _frame.Height = _baseH;

        if (_cropSquarePreview && !_fullLoaded)
        {
            var side = Math.Min(_baseW, _baseH);
            _preview.Width = side;
            _preview.Height = side;
        }
        else
        {
            _preview.Width = double.NaN;
            _preview.Height = double.NaN;
        }

        ApplyView(ViewerMath.ClampPhotoView(_view, _baseW, _baseH, _viewW, _viewH));
    }

    Rect FittedRect(Rect bounds)
    {
        if (_natW > 0 && _natH > 0) return ViewerMath.FitMedia(bounds, _natW, _natH);
        return ViewerMath.FitAspect(bounds, Item.CardAspectRatio);
    }

    public Rect MediaFrame(Rect viewportBounds)
    {
        var w = viewportBounds.Width > 0 ? viewportBounds.Width : _viewW;
        var h = viewportBounds.Height > 0 ? viewportBounds.Height : _viewH;
        if (w <= 0 || h <= 0) return viewportBounds;
        var fitted = FittedRect(new Rect(0, 0, w, h));
        return ViewerMath.PhotoMediaFrame(w, h, fitted.Width, fitted.Height, _view);
    }

    public void ZoomByFactor(double factor, Point viewportPoint)
    {
        if (_viewW <= 0 || _viewH <= 0) return;
        _animating = false;
        var next = ViewerMath.ZoomPhotoAt(_view, _view.Scale * factor, viewportPoint.X, viewportPoint.Y, _baseW, _baseH, _viewW, _viewH);
        ApplyView(next);
    }

    public void ZoomToScale(double targetScale, Point viewportPoint, double now, bool animate = true)
    {
        if (_viewW <= 0 || _viewH <= 0) return;
        var target = targetScale <= 1.01
            ? PhotoView.Identity
            : ViewerMath.ZoomPhotoAt(_view, targetScale, viewportPoint.X, viewportPoint.Y, _baseW, _baseH, _viewW, _viewH);
        if (!animate)
        {
            _animating = false;
            ApplyView(target);
            return;
        }
        _animFrom = _view;
        _animTo = target;
        _animStart = now;
        _animating = true;
    }

    public void ToggleDoubleTapZoom(Point viewportPoint, double now)
    {
        var target = _view.Scale > 1.01 ? ViewerMath.MinPhotoZoom : ViewerMath.DoubleClickZoom;
        ZoomToScale(target, viewportPoint, now, animate: true);
    }

    public void PanBy(double dx, double dy)
    {
        if (!_view.IsZoomed || _viewW <= 0 || _viewH <= 0) return;
        _animating = false;
        ApplyView(ViewerMath.ClampPhotoView(new PhotoView(_view.Scale, _view.X + dx, _view.Y + dy), _baseW, _baseH, _viewW, _viewH));
    }

    public void ResetZoom()
    {
        _animating = false;
        ApplyView(PhotoView.Identity);
    }

    public bool TickAnimation(double now)
    {
        if (!_animating) return false;
        var t = Math.Clamp((now - _animStart) / ZoomAnimDuration, 0.0, 1.0);
        var e = ViewerMath.EaseOutCubic(t);
        var cur = new PhotoView(
            ViewerMath.Lerp(_animFrom.Scale, _animTo.Scale, e),
            ViewerMath.Lerp(_animFrom.X, _animTo.X, e),
            ViewerMath.Lerp(_animFrom.Y, _animTo.Y, e));
        ApplyView(ViewerMath.ClampPhotoView(cur, _baseW, _baseH, _viewW, _viewH));
        if (t >= 1.0)
        {
            _animating = false;
            ApplyView(_animTo);
            return false;
        }
        return true;
    }

    void ApplyView(PhotoView next)
    {
        _view = next;
        _transform.ScaleX = next.Scale;
        _transform.ScaleY = next.Scale;
        _transform.TranslateX = next.X;
        _transform.TranslateY = next.Y;
        var z = next.IsZoomed;
        if (z != _wasZoomed)
        {
            _wasZoomed = z;
            ZoomChanged?.Invoke(z);
        }
    }

    public void Teardown()
    {
        _animating = false;
        _loading?.Cancel();
        _loading = null;
        _full.Source = null;
        _preview.Source = null;
    }
}
