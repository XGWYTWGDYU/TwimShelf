// The tag adder (a card's "+", the menus' 添加标签), as the other apps have it: type to filter the
// existing tags (yours first, then by use) or to create one; Enter adds what is typed and the picker
// stays open for more; for a media of a post, this media or the whole post.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Core;
using TwimShelf.Models;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public static class TagPicker
{
    public static async Task Show(FeedItem media, bool wholePost)
    {
        var w = MainWindow.Current!;
        var all = await TlCore.Run(TlCore.AllTags);
        var scope = await TlCore.Run(() => TlCore.PostScope(media.PostId));
        var loose = media.IsLoose();
        var whole = wholePost && !loose;
        var added = new List<string>();
        var receipts = new Dictionary<string, List<ActionReceipt>>();
        var query = new TextBox { PlaceholderText = L("tagPicker.placeholder") };
        var error = new TextBlock { Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"], Visibility = Visibility.Collapsed, Text = L("tagPicker.error") };
        var list = new StackPanel { Spacing = 2 };
        var panel = new StackPanel { Spacing = 10, Width = 400 };
        Segmented? seg = null;
        if (!loose)
        {
            seg = new Segmented { HorizontalAlignment = HorizontalAlignment.Stretch };
            seg.Items.Add(new SegmentedItem { Content = L("tagPicker.thisMedia") });
            seg.Items.Add(new SegmentedItem { Content = L("tagPicker.wholePost", scope.Ids.Count) });
            seg.SelectedIndex = whole ? 1 : 0;
            panel.Children.Add(seg);
        }
        if (scope.PendingCount > 0) panel.Children.Add(new TextBlock { Text = L("tagPicker.pending", scope.PendingCount), Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
        panel.Children.Add(query);
        panel.Children.Add(error);
        panel.Children.Add(new ScrollViewer { Content = list, Height = 340 });

        List<string> Targets() => whole ? scope.Ids : [media.MediaId];
        HashSet<string> Existing()
        {
            var ids = Targets();
            if (ids.Count == 0) return [];
            var common = (scope.UserTags.GetValueOrDefault(ids[0]) ?? []).ToHashSet();
            foreach (var id in ids.Skip(1)) common.IntersectWith(scope.UserTags.GetValueOrDefault(id) ?? []);
            return common;
        }
        string Trimmed() => query.Text.Trim().ToLowerInvariant();
        int Tagged(string label) => Targets().Count(id => (scope.UserTags.GetValueOrDefault(id) ?? []).Contains(label));

        Button Row(string glyph, Brush? tint, string text, string? trailing, Action click)
        {
            var g = new Grid { ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
            var icon = new FontIcon { Glyph = glyph, FontSize = 14, Margin = new Thickness(0, 0, 12, 0) };
            if (tint != null) icon.Foreground = tint;
            g.Children.Add(icon);
            var t = new TextBlock { Text = text, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetColumn(t, 1);
            g.Children.Add(t);
            if (trailing != null)
            {
                var tr = new TextBlock { Text = trailing, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(tr, 2);
                g.Children.Add(tr);
            }
            var b = new Button { Content = g, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(10, 6, 10, 6) };
            b.Click += (_, _) => click();
            return b;
        }
        TextBlock Header(string s) => new() { Text = s, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Margin = new Thickness(10, 10, 0, 2), Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] };

        var accent = (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"];
        void Build()
        {
            list.Children.Clear();
            var q = Trimmed();
            var existing = Existing();
            if (q.Length > 0 && all.All(t => t.Label != q) && !existing.Contains(q))
                list.Children.Add(Row("", accent, L("tagPicker.create", q), null, () => Add(q)));
            if (added.Count > 0)
            {
                list.Children.Add(Header(L("tagPicker.justAdded")));
                foreach (var t in added.ToList()) list.Children.Add(Row("", accent, t, L("common.undo"), () => UndoAdd(t)));
            }
            list.Children.Add(Header(q.Length == 0 ? L("tagPicker.frequent") : L("tagPicker.matching")));
            var suggestions = all.Where(t => !existing.Contains(t.Label) && (q.Length == 0 || t.Label.Contains(q)))
                .OrderByDescending(t => t.User > 0 ? 1 : 0).ThenByDescending(t => t.Count).Take(40);
            foreach (var t in suggestions)
                list.Children.Add(Row(t.User > 0 ? "" : "", t.User > 0 ? accent : null, t.Label, L("tagPicker.tagged", Tagged(t.Label), Targets().Count), () => Add(t.Label)));
        }

        async void Add(string label)
        {
            var l = label.Trim().ToLowerInvariant();
            if (l.Length == 0 || Existing().Contains(l)) return;
            try
            {
                var r = await TlCore.Run(() => TlCore.Action(ActionKind.Tag, whole ? [] : [media.MediaId], whole ? [media.PostId] : [], null, l));
                (receipts.TryGetValue(l, out var rs) ? rs : receipts[l] = []).Add(r);
            }
            catch { error.Visibility = Visibility.Visible; return; }
            scope = await TlCore.Run(() => TlCore.PostScope(media.PostId));
            if (!added.Contains(l)) added.Add(l);
            query.Text = "";
            error.Visibility = Visibility.Collapsed;
            Build();
            _ = LibraryModel.Current.Refresh();
        }

        async void UndoAdd(string label)
        {
            try
            {
                var rs = receipts[label];
                while (rs.Count > 0) { var last = rs[^1]; await TlCore.Run(() => TlCore.Undo(last)); rs.RemoveAt(rs.Count - 1); }
                receipts.Remove(label);
                added.Remove(label);
                scope = await TlCore.Run(() => TlCore.PostScope(media.PostId));
                error.Visibility = Visibility.Collapsed;
                Build();
                _ = LibraryModel.Current.Refresh();
            }
            catch { error.Visibility = Visibility.Visible; }
        }

        var d = new ContentDialog { Title = loose ? L("tagPicker.title") : null, Content = panel, CloseButtonText = L("common.done"), DefaultButton = ContentDialogButton.Close };
        if (seg != null) seg.SelectionChanged += (_, _) => { whole = seg.SelectedIndex == 1; Build(); };
        query.TextChanged += (_, _) => Build();
        query.KeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter) return;
            e.Handled = true;
            if (Trimmed().Length == 0) d.Hide(); else Add(Trimmed());
        };
        d.Opened += (_, _) => query.Focus(FocusState.Programmatic);
        Build();
        await Dialogs.ShowAsync(w, d);
    }
}
