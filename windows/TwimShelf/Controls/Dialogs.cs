// The app's dialogs (ContentDialog): a question with a field, a choice, a message, and work with
// progress. One at a time per window, as WinUI allows.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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
    public static async Task<int> Choose(Window w, string title, string message, params string[] actions)
    {
        var d = new ContentDialog
        {
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = actions.Length > 0 ? actions[0] : "",
            SecondaryButtonText = actions.Length > 1 ? actions[1] : "",
            CloseButtonText = L("common.cancel"),
        };
        return await ShowAsync(w, d) switch { ContentDialogResult.Primary => 0, ContentDialogResult.Secondary => 1, _ => -1 };
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

    /// A short message that goes by itself (a TeachingTip at the bottom of the window).
    public static void Toast(Window w, string message, string? action = null, Action? onAction = null)
    {
        if (w.Content is not Panel root) return;
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
}
