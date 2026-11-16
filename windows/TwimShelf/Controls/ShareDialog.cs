// The import page for what was sent here (发送到) or dropped on the window: what came, the folder it
// goes into (or none), links downloaded first into a staging folder. Nothing reaches the library
// until 导入; closing it any other way deletes what was brought here.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public static class ShareDialog
{
    static bool IsVideo(string p) => new[] { ".mp4", ".mov", ".m4v", ".webm", ".mkv" }.Any(e => p.EndsWith(e, StringComparison.OrdinalIgnoreCase));

    public static async Task Show(Window w, LibraryModel library, ShareNeedsChoice batch)
    {
        ShareStaged? staged = null;
        string? problem = null;
        var folder = "";
        var made = new List<string>();
        var body = new StackPanel { Spacing = 12, Width = 480 };
        var folderBox = new ComboBox { MinWidth = 200 };
        // 新建文件夹… names it right here: a second dialog can't open over this one (it waited
        // until this one closed)
        var newName = new TextBox { PlaceholderText = L("common.folderName"), MinWidth = 240 };
        var create = new Button { Content = L("common.create") };
        var newRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed, Children = { newName, create } };
        var d = new ContentDialog
        {
            Title = L("common.import"),
            Content = new ScrollViewer { Content = body, MaxHeight = 560 },
            PrimaryButtonText = L("share.import"),
            CloseButtonText = L("common.close"),
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };

        List<(string Path, bool Video)> Media() => [.. batch.Files.Select(f => (f, IsVideo(f))), .. (staged?.Items ?? []).Select(i => (i.Path, i.IsVideo))];
        bool Downloading() => batch.Links.Count > 0 && staged == null && problem == null;

        void FillFolders()
        {
            folderBox.Items.Clear();
            folderBox.Items.Add(new ComboBoxItem { Content = L("share.noFolder"), Tag = "" });
            foreach (var f in made.Concat((library.Folders?.Folders ?? []).Select(x => x.Name).Where(n => !made.Contains(n))))
                folderBox.Items.Add(new ComboBoxItem { Content = f, Tag = f });
            folderBox.Items.Add(new ComboBoxItem { Content = L("common.newFolderEllipsis"), Tag = "\0new" });
            folderBox.SelectedItem = folderBox.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == folder);
        }

        void Build()
        {
            body.Children.Clear();
            var media = Media();
            if (Downloading())
            {
                body.Children.Add(new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, Children = { new ProgressRing { IsActive = true }, new TextBlock { Text = L("share.downloading", batch.Links.Count) } } });
                d.IsPrimaryButtonEnabled = false;
                return;
            }
            if (media.Count == 0) body.Children.Add(new TextBlock { Text = L("share.nothing") });
            else
            {
                long bytes = 0;
                foreach (var (p, _) in media) { try { bytes += new FileInfo(p).Length; } catch { } }
                var kind = media.Count == 1 && media[0].Path.Contains('.') ? Path.GetExtension(media[0].Path).TrimStart('.').ToUpperInvariant() + " · " : "";
                body.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Informational, Title = L("share.readyCount", media.Count), Message = kind + Format.Bytes(bytes) });
                var thumbs = new GridView { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = false, MaxHeight = 240 };
                foreach (var (p, video) in media.Take(8))
                {
                    var tile = new Grid { Width = 100, Height = 100, CornerRadius = new CornerRadius(6), Background = (Brush)Application.Current.Resources["ControlFillColorSecondaryBrush"] };
                    if (video) tile.Children.Add(new FontIcon { Glyph = "", FontSize = 32 });
                    else tile.Children.Add(new Image { Stretch = Stretch.UniformToFill, Source = new BitmapImage { DecodePixelWidth = 200, UriSource = new Uri(p) } });
                    thumbs.Items.Add(tile);
                }
                body.Children.Add(thumbs);
                if (media.Count > 8) body.Children.Add(new TextBlock { Text = $"+{media.Count - 8}", Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
                body.Children.Add(new TextBlock { Text = L("share.hint"), TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
                if (staged?.Items.FirstOrDefault()?.Text is { Length: > 0 } text)
                    body.Children.Add(new TextBlock { Text = text, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.Wrap });
                body.Children.Add(new SettingsCard { Header = L("share.targetFolder"), HeaderIcon = new FontIcon { Glyph = "" }, Content = folderBox });
                body.Children.Add(newRow);
            }
            var problems = (staged?.Failed ?? []).Select(f => $"{f.Link}\n{f.Reason}").ToList();
            if (problem != null) problems.Add(problem);
            if (problems.Count > 0)
                body.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Message = string.Join("\n\n", problems) });
            d.IsPrimaryButtonEnabled = media.Count > 0;
        }

        FillFolders();
        folderBox.SelectionChanged += (_, _) =>
        {
            if (folderBox.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
            if (tag != "\0new") { folder = tag; newRow.Visibility = Visibility.Collapsed; return; }
            newRow.Visibility = Visibility.Visible;
            newName.Focus(FocusState.Programmatic);
        };
        void Create()
        {
            var n = newName.Text.Trim();
            if (n.Length == 0) return;
            if (!made.Contains(n)) made.Insert(0, n);
            folder = n;
            newName.Text = "";
            newRow.Visibility = Visibility.Collapsed;
            FillFolders();
        }
        create.Click += (_, _) => Create();
        // Enter makes the folder (not the dialog's 导入)
        newName.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { Create(); e.Handled = true; } };
        Build();
        if (batch.Links.Count > 0)
            _ = Task.Run(async () =>
            {
                try { staged = await library.Shares.Stage(batch.Id, batch.Links); }
                catch (Exception e) { problem = e.Message; }
                w.DispatcherQueue.TryEnqueue(Build);
            });
        var imported = false;
        d.PrimaryButtonClick += async (_, a) =>
        {
            var deferral = a.GetDeferral();
            try
            {
                await library.Shares.Confirm(batch, folder.Length == 0 ? null : folder, staged?.Items.Count > 0);
                imported = true;
            }
            catch (Exception e) { problem = e.Message; a.Cancel = true; Build(); }
            deferral.Complete();
        };
        await Dialogs.ShowAsync(w, d);
        if (!imported) await library.Shares.Discard(batch);
    }
}
