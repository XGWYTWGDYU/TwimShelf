// The app's dialogs (ContentDialog): a question with a field, a choice, a message, and work with
// progress. One at a time per window, as WinUI allows.
using System.Numerics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public static class Dialogs
{
    static readonly SemaphoreSlim Gate = new(1, 1);

    static XamlRoot Root(Window w) => w.Content.XamlRoot;

    public static async Task<ContentDialogResult> ShowAsync(Window w, ContentDialog d)
    {
        // a window just shown has no XamlRoot until its content loads (a question at start-up)
        for (var i = 0; i < 100 && w.Content?.XamlRoot == null; i++) await Task.Delay(50);
        d.XamlRoot = Root(w);
        d.RequestedTheme = (w.Content as FrameworkElement)?.RequestedTheme ?? ElementTheme.Default;
        d.Style ??= (Style)Application.Current.Resources["DefaultContentDialogStyle"];
        await Gate.WaitAsync();
        try { return await d.ShowAsync(); }
        finally { Gate.Release(); }
    }

    /// A name or text: null when cancelled.
    public static async Task<string?> Prompt(Window w, string title, string placeholder, string initial = "", string? message = null, string? primary = null)
    {
        var box = new TextBox { PlaceholderText = placeholder, Text = initial, SelectionStart = 0, SelectionLength = initial.Length, MinWidth = 320 };
        var panel = new StackPanel { Spacing = 12 };
        if (message != null) panel.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(box);
        var d = new ContentDialog
        {
            Title = title,
            Content = panel,
            PrimaryButtonText = primary ?? L("common.ok"),
            CloseButtonText = L("common.cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { d.Hide(); _done = true; } };
        _done = false;
        d.Opened += (_, _) => box.Focus(FocusState.Programmatic);
        var r = await ShowAsync(w, d);
        return r == ContentDialogResult.Primary || _done ? box.Text : null;
    }
    static bool _done;

    /// A question with one action (destructive ones say so in their text): true when chosen.
    public static async Task<bool> Confirm(Window w, string title, string message, string action, bool destructive = false)
    {
        var d = new ContentDialog
        {
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = action,
            CloseButtonText = L("common.cancel"),
            DefaultButton = destructive ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        return await ShowAsync(w, d) == ContentDialogResult.Primary;
    }

    /// One of several actions: its index, or -1 when cancelled.
    /// The actions are buttons of their own, one under the other and as wide as the dialog: in
    /// the dialog's own button row each gets a third of it, and a longer label is cut off.
    public static async Task<int> Choose(Window w, string title, string message, params string[] actions)
    {
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
        var d = new ContentDialog { Title = title, Content = panel, CloseButtonText = L("common.cancel") };
        var chosen = -1;
        for (var i = 0; i < actions.Length; i++)
        {
            var index = i;
            var b = new Button
            {
                Content = new TextBlock { Text = actions[i], TextWrapping = TextWrapping.Wrap },
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Padding = new Thickness(12, 8, 12, 8),
            };
            if (i == 0) b.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            b.Click += (_, _) => { chosen = index; d.Hide(); };
            panel.Children.Add(b);
        }
        await ShowAsync(w, d);
        return chosen;
    }

    public static async Task Alert(Window w, string title, string? message = null)
    {
        var d = new ContentDialog
        {
            Title = title,
            Content = message == null ? null : new ScrollViewer { Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }, MaxHeight = 480 },
            CloseButtonText = L("common.ok"),
            DefaultButton = ContentDialogButton.Close,
        };
        await ShowAsync(w, d);
    }

    /// Work that takes a while: a dialog with its progress (polled) and a Cancel when it can stop.
    public static async Task<T> Progress<T>(Window w, string title, Func<T> work, Func<string?>? progress = null, Action? cancel = null)
    {
        var text = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = "" };
        var bar = new ProgressBar { IsIndeterminate = true, MinWidth = 320 };
        var d = new ContentDialog
        {
            Title = title,
            Content = new StackPanel { Spacing = 12, Children = { bar, text } },
            CloseButtonText = cancel != null ? L("common.cancel") : "",
        };
        if (cancel != null) d.CloseButtonClick += (_, a) => { a.Cancel = true; cancel(); d.IsEnabled = false; };
        var timer = w.DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(400);
        timer.Tick += (_, _) => { var t = progress?.Invoke(); if (t != null) text.Text = t; };
        timer.Start();
        var task = Task.Run(work);
        _ = task.ContinueWith(_ => w.DispatcherQueue.TryEnqueue(() => d.Hide()), TaskScheduler.Default);
        // work that ended before the dialog opened: hiding it then did nothing, and it has no button
        d.Opened += (_, _) => { if (task.IsCompleted) d.Hide(); };
        _ = ShowAsync(w, d);
        try { return await task; }
        finally { timer.Stop(); }
    }

    static (Panel Root, Border Toast, DispatcherQueueTimer Timer)? _activeToast;

    /// A short message that goes by itself: plain messages use a compact self-sizing toast with
    /// centered text at the bottom of the window; messages with an action (e.g. Undo) use TeachingTip.
    public static void Toast(Window w, string message, string? action = null, Action? onAction = null)
    {
        if (w.Content is not Panel root) return;
        if (action == null && onAction == null)
        {
            ShowCompactToast(w, root, message);
            return;
        }
        var tip = new TeachingTip
        {
            Subtitle = message,
            PreferredPlacement = TeachingTipPlacementMode.Bottom,
            IsLightDismissEnabled = true,
            ActionButtonContent = action,
            PlacementMargin = new Thickness(24),
        };
        if (onAction != null) tip.ActionButtonClick += (_, _) => { tip.IsOpen = false; onAction(); };
        tip.Closed += (_, _) => root.Children.Remove(tip);
        root.Children.Add(tip);
        tip.IsOpen = true;
        var t = w.DispatcherQueue.CreateTimer();
        t.Interval = TimeSpan.FromSeconds(onAction != null ? 6 : 3.5);
        t.IsRepeating = false;
        t.Tick += (_, _) => tip.IsOpen = false;
        t.Start();
    }

    static void ShowCompactToast(Window w, Panel root, string message)
    {
        if (_activeToast is { } prev)
        {
            prev.Timer.Stop();
            prev.Root.Children.Remove(prev.Toast);
            _activeToast = null;
        }
        var toast = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(24),
            MaxWidth = 420,
            Padding = new Thickness(16, 10, 16, 10),
            CornerRadius = new CornerRadius(8),
            Background = (Brush)Application.Current.Resources["AcrylicInAppFillColorDefaultBrush"],
            BorderBrush = (Brush)Application.Current.Resources["SurfaceStrokeColorFlyoutBrush"],
            BorderThickness = new Thickness(1),
            Shadow = new ThemeShadow(),
            Translation = new Vector3(0, 0, 32),
            IsHitTestVisible = false,
            Opacity = 0,
            OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(160) },
            Child = new TextBlock
            {
                Text = message,
                TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
                Foreground = (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"],
            },
        };
        if (root is Grid grid)
        {
            if (grid.RowDefinitions.Count > 1) Grid.SetRowSpan(toast, grid.RowDefinitions.Count);
            if (grid.ColumnDefinitions.Count > 1) Grid.SetColumnSpan(toast, grid.ColumnDefinitions.Count);
        }
        Canvas.SetZIndex(toast, 1000);
        toast.Loaded += (_, _) => toast.Opacity = 1;
        root.Children.Add(toast);

        var t = w.DispatcherQueue.CreateTimer();
        t.Interval = TimeSpan.FromSeconds(3.5);
        t.IsRepeating = false;
        t.Tick += (_, _) =>
        {
            toast.Opacity = 0;
            var remove = w.DispatcherQueue.CreateTimer();
            remove.Interval = TimeSpan.FromMilliseconds(180);
            remove.IsRepeating = false;
            remove.Tick += (_, _) =>
            {
                root.Children.Remove(toast);
                if (_activeToast?.Toast == toast) _activeToast = null;
            };
            remove.Start();
        };
        _activeToast = (root, toast, t);
        t.Start();
    }
}
