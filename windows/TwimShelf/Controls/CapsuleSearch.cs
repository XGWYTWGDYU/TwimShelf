// The search field of 浏览 (in the title bar, as the Mac toolbar has it): finished words turn into
// capsules (a condition word, a folder, a term; with a leading minus they leave out), Backspace at
// the start takes the last capsule, and while typing a panel under the field suggests condition
// words, tags, folders and recent searches. Every change reports the whole query.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Core;
using TwimShelf.Search;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public sealed partial class CapsuleSearch : UserControl
{
    public event Action<TokenQuery>? Changed;
    public Func<List<(string Name, long Count)>> Folders { get; set; } = () => [];
    List<string> _keys = [];
    readonly StackPanel _chips = new() { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
    readonly ScrollViewer _chipScroll;
    readonly TextBox _text;
    readonly Button _clear;
    readonly Border _searchIcon = new() { Width = 18, Margin = new Thickness(12, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly Popup _popup = new() { IsLightDismissEnabled = false };
    readonly StackPanel _rows = new();
    readonly Border _panel;
    List<TagCount> _tags = [];
    string? _setText; // what SetText put in, until its TextChanged arrives

    public IReadOnlyList<string> Keys => _keys;

    /// Narrow (浏览's bar drawn into the corner): the short placeholder.
    public bool Compact
    {
        get => _compact;
        set { _compact = value; _text.PlaceholderText = _keys.Count == 0 ? Placeholder : ""; }
    }
    bool _compact;
    string Placeholder => _compact ? L("common.search") : L("search.placeholder");

    public CapsuleSearch()
    {
        _text = new TextBox
        {
            PlaceholderText = L("search.placeholder"),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            VerticalAlignment = VerticalAlignment.Center,
            MinWidth = 80,
            Padding = new Thickness(4, 5, 4, 5),
        };
        // the field's own focus look would draw a box inside the capsule
        _text.Resources["TextControlBackgroundFocused"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _text.Resources["TextControlBackgroundPointerOver"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _text.Resources["TextControlBorderBrushFocused"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(_text, "search");
        _chipScroll = new ScrollViewer
        {
            Content = _chips,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Enabled,
            VerticalScrollMode = ScrollMode.Disabled,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _clear = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 12 },
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(8, 6, 8, 6),
            Visibility = Visibility.Collapsed,
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(_clear, L("common.clear"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_clear, L("common.clear"));
        _clear.Click += (_, _) => Clear();
        var grid = new Grid
        {
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        UpdateSearchIcon();
        grid.Children.Add(_searchIcon);
        Grid.SetColumn(_chipScroll, 1);
        grid.Children.Add(_chipScroll);
        Grid.SetColumn(_text, 2);
        grid.Children.Add(_text);
        Grid.SetColumn(_clear, 3);
        grid.Children.Add(_clear);
        Content = new Border
        {
            Child = grid,
            MinHeight = 34,
            CornerRadius = new CornerRadius(17),
            Background = (Brush)Application.Current.Resources["ControlFillColorDefaultBrush"],
            BorderBrush = (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"],
            BorderThickness = new Thickness(1),
        };
        _panel = new Border
        {
            Child = new ScrollViewer { Content = _rows, MaxHeight = 420, Padding = new Thickness(0, 4, 0, 8) },
            CornerRadius = new CornerRadius(8),
            Background = (Brush)Application.Current.Resources["AcrylicInAppFillColorDefaultBrush"],
            BorderBrush = (Brush)Application.Current.Resources["SurfaceStrokeColorFlyoutBrush"],
            BorderThickness = new Thickness(1),
            Shadow = new ThemeShadow(),
            Translation = new System.Numerics.Vector3(0, 0, 32),
        };
        _popup.Child = _panel;
        // TextChanged comes after the change (queued), so a flag set around the change is already
        // cleared: the text this field set itself is recognised instead (Enter clearing it reopened
        // the suggestions)
        _text.TextChanged += (_, _) =>
        {
            var mine = _setText != null && _text.Text == _setText;
            _setText = null;
            if (!mine) Typed();
        };
        _text.KeyDown += OnKey;
        // focus that moved here on its own (the viewer closing, a page changing) opens nothing; a
        // click, the keyboard, or this control's own Focus calls (FocusText) do
        // what moved focus: a card scrolled away and recycled with focus inside hands it to the first
        // focusable element (this field), labelled with the last input (the mouse), not Programmatic
        _text.GettingFocus += (_, e) => _byUser = e.InputDevice != FocusInputDeviceKind.None;
        _text.GotFocus += async (_, _) =>
        {
            var byUser = _byUser;
            _byUser = false;
            if (!byUser && !_ownFocus) return;
            if (_text.FocusState == FocusState.Programmatic && !_ownFocus) return;
            _ownFocus = false;
            ShowPanel();
            _tags = await TlCore.Run(TlCore.AllTags);
            BuildRows();
        };
        // the chips may take most of the field: kept to its width as it grows and shrinks (浏览's bar)
        SizeChanged += (_, _) => { _chipScroll.MaxWidth = Math.Max(120, ActualWidth * 0.6); if (_popup.IsOpen) Reposition(); };
        _text.LostFocus += (_, _) => DispatcherQueue.TryEnqueue(async () => { await Task.Delay(180); if (FocusManager.GetFocusedElement(XamlRoot) is not FrameworkElement f || !IsInPanel(f)) _popup.IsOpen = false; });
        SizeChanged += (_, _) => _panel.Width = ActualWidth;
        _popup.Loaded += (_, _) => _panel.Width = ActualWidth;
    }

    bool IsInPanel(DependencyObject d)
    {
        for (var x = d; x != null; x = VisualTreeHelper.GetParent(x)) if (x == _panel) return true;
        return false;
    }

    // ---- the query ----------------------------------------------------------------------------

    public TokenQuery Query
    {
        get
        {
            var rest = _text.Text.Trim();
            var keys = _keys.ToList();
            if (rest.Length > 0 && TokenQuery.Negated(rest + "x") != "x")
            {
                var last = keys.Count == 0 ? null : keys[^1];
                var key = TokenQuery.KeyFor(rest, last);
                if (last == TokenQuery.PendingFolder || last == "-" + TokenQuery.PendingFolder) keys[^1] = key;
                else keys.Add(key);
            }
            return new TokenQuery(keys);
        }
    }

    /// The capsules from outside (a filter of 浏览 as a search); what is typed stays.
    public void SetKeys(IEnumerable<string> keys)
    {
        _keys = [.. keys];
        BuildChips();
        Changed?.Invoke(Query);
    }

    /// One capsule from outside (a card's 搜索此标签).
    public void AddKey(string key)
    {
        _keys = Append(_keys, key);
        BuildChips();
        Changed?.Invoke(Query);
    }

    static List<string> Append(List<string> keys, string key)
    {
        var last = keys.Count == 0 ? null : keys[^1];
        if ((last == TokenQuery.PendingFolder || last == "-" + TokenQuery.PendingFolder) && key.Contains("d:")) return [.. keys.Take(keys.Count - 1), key];
        return keys.Contains(key) ? keys : [.. keys, key];
    }

    void SetText(string t)
    {
        if (_text.Text != t) { _setText = t; _text.Text = t; }
        _text.SelectionStart = t.Length;
    }

    void Typed()
    {
        var split = TokenQuery.Split(_text.Text);
        if (split.Keys.Count > 0)
        {
            foreach (var k in split.Keys) _keys = Append(_keys, k);
            SetText(split.Remaining);
            BuildChips();
        }
        _clear.Visibility = _keys.Count > 0 || _text.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        BuildRows();
        Changed?.Invoke(Query);
    }

    void OnKey(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case Windows.System.VirtualKey.Back when _text.SelectionStart == 0 && _text.SelectionLength == 0 && _keys.Count > 0:
                _keys = [.. _keys.Take(_keys.Count - 1)];
                BuildChips();
                Changed?.Invoke(Query);
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Enter:
                Submit();
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Escape:
                _popup.IsOpen = false;
                e.Handled = true;
                break;
        }
    }

    void Submit()
    {
        var q = Query;
        if (q.Keys.Count > 0) SearchHistory.Add(string.Join(' ', q.Keys.Select(Word)));
        _keys = [.. q.Keys];
        SetText("");
        BuildChips();
        _popup.IsOpen = false;
        Changed?.Invoke(Query);
    }

    /// A key written back as typed (for the history).
    static string Word(string key)
    {
        var ex = TokenQuery.IsExcluded(key);
        var bare = ex ? key[1..] : key;
        var w = bare.StartsWith("d:") ? $"{SearchKeyword.Folder.Word} {bare[2..]}" : TokenQuery.Title(bare);
        return ex ? "-" + w : w;
    }

    public void Clear()
    {
        _keys = [];
        SetText("");
        BuildChips();
        Changed?.Invoke(Query);
    }

    public new void Focus(FocusState s) { _ownFocus = _text.FocusState == FocusState.Unfocused; _text.Focus(s); }
    /// Its text field has the focus (the control itself never does).
    bool _byUser;

    public bool HasFocus => _text.FocusState != FocusState.Unfocused;

    // ---- capsules -------------------------------------------------------------------------------

    void BuildChips()
    {
        UpdateSearchIcon();
        _chips.Children.Clear();
        foreach (var k in _keys)
        {
            var excluded = TokenQuery.IsExcluded(k);
            var key = k;
            var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            if (excluded) label.Children.Add(new FontIcon { Glyph = "", FontSize = 10 });
            label.Children.Add(new TextBlock { Text = TokenQuery.Title(k), FontSize = 13 });
            label.Children.Add(new FontIcon { Glyph = "", FontSize = 9, Margin = new Thickness(2, 0, 0, 0), Opacity = 0.7 });
            var chip = new Button
            {
                Content = label,
                Padding = new Thickness(10, 2, 8, 2),
                CornerRadius = new CornerRadius(12),
                MinHeight = 24,
                BorderThickness = new Thickness(0),
                Background = (Brush)Application.Current.Resources[excluded ? "SystemFillColorCriticalBackgroundBrush" : "AccentFillColorTertiaryBrush"],
                Foreground = excluded ? (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"] : (Brush)Application.Current.Resources["TextOnAccentFillColorPrimaryBrush"],
            };
            // the same colours under the pointer and pressed: a capsule does not light up
            foreach (var state in new[] { "PointerOver", "Pressed" })
            {
                chip.Resources["ButtonBackground" + state] = chip.Background;
                chip.Resources["ButtonForeground" + state] = chip.Foreground;
                chip.Resources["ButtonBorderBrush" + state] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            }
            ToolTipService.SetToolTip(chip, TokenQuery.Spoken(k));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(chip, TokenQuery.Spoken(k));
            chip.Click += (_, _) => { _keys.Remove(key); _keys = [.. _keys]; BuildChips(); Changed?.Invoke(Query); FocusText(); };
            _chips.Children.Add(chip);
        }
        _chipScroll.MaxWidth = Math.Max(120, ActualWidth * 0.6);
        _chipScroll.Visibility = _keys.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _text.PlaceholderText = _keys.Count == 0 ? Placeholder : "";
        _clear.Visibility = _keys.Count > 0 || _text.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        DispatcherQueue.TryEnqueue(() => _chipScroll.ChangeView(_chipScroll.ScrollableWidth, null, null, true));
        BuildRows();
    }

    public void UpdateSearchIcon()
    {
        var mascot = Clawd.On && _keys.Count > 0;
        if (_searchIcon.Child != null && (_searchIcon.Child is ImageIcon) == mascot) return;
        _searchIcon.Child = mascot ? Clawd.Icon("search", 18) : new FontIcon
        {
            Glyph = "", FontSize = 14,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        };
    }

    // ---- suggestions ------------------------------------------------------------------------------

    bool _ownFocus;
    void FocusText() { _ownFocus = _text.FocusState == FocusState.Unfocused; _text.Focus(FocusState.Programmatic); }

    void ShowPanel()
    {
        if (XamlRoot == null) return;
        _popup.XamlRoot = XamlRoot;
        Reposition();
        BuildRows();
    }

    /// Under the field again (浏览's bar moves and widens as it scrolls).
    public void Reposition()
    {
        if (XamlRoot == null) return;
        var p = TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(0, ActualHeight + 6));
        _popup.HorizontalOffset = p.X;
        _popup.VerticalOffset = p.Y;
        _panel.Width = ActualWidth;
    }

    void BuildRows()
    {
        _rows.Children.Clear();
        var sections = Suggestions.Sections(_text.Text, _keys, _tags, Folders(), SearchHistory.Items, Prefs.Instance.AboutExtras);
        foreach (var s in sections.Where(s => s.Rows.Count > 0))
        {
            _rows.Children.Add(new TextBlock { Text = s.Title, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], Margin = new Thickness(16, 10, 16, 4) });
            foreach (var r in s.Rows) _rows.Children.Add(Row(r));
        }
        var focused = _text.FocusState != FocusState.Unfocused;
        // an unparented popup needs its XamlRoot before it opens (a chip's × rebuilds the rows
        // before the field has the focus, so ShowPanel may not have set it yet)
        var open = focused && _rows.Children.Count > 0 && XamlRoot != null;
        if (open) { _popup.XamlRoot = XamlRoot; Reposition(); }
        _popup.IsOpen = open;
    }

    Button Row(Suggestion r)
    {
        var tint = r.Destructive || r.Tint == SuggestionTint.Exclude ? (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"]
            : r.Tint == SuggestionTint.Secondary ? (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]
            : (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"];
        var g = new Grid { ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() } };
        g.Children.Add(new FontIcon { Glyph = r.Glyph, FontSize = 14, Foreground = tint, Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center });
        var text = new StackPanel();
        var label = new TextBlock { Text = r.Label, TextTrimming = TextTrimming.CharacterEllipsis };
        if (r.Destructive) label.Foreground = tint;
        text.Children.Add(label);
        if (r.Detail != null) text.Children.Add(new TextBlock { Text = r.Detail, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], TextTrimming = TextTrimming.CharacterEllipsis });
        Grid.SetColumn(text, 1);
        g.Children.Add(text);
        var b = new Button
        {
            Content = g,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(16, 6, 16, 6),
            Margin = new Thickness(4, 0, 4, 0),
            IsEnabled = r.Kind != SuggestionKind.Empty,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(b, "suggest-" + r.Id);
        b.Click += (_, _) => Pick(r);
        return b;
    }

    void Pick(Suggestion r)
    {
        switch (r.Kind)
        {
            case SuggestionKind.ClearHistory: SearchHistory.Clear(); break;
            case SuggestionKind.History:
                _keys = TokenQuery.Split(r.Label + " ").Keys;
                SetText("");
                break;
            case SuggestionKind.Empty: return;
            default:
                if (r.Key == null) return;
                _keys = Append(_keys, r.Key);
                SetText("");
                break;
        }
        BuildChips();
        Changed?.Invoke(Query);
        FocusText();
    }
}
