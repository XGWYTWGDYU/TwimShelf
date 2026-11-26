// 浏览器扩展: downloads/updates the app-hosted extension in the app's data folder, binds Chromium
// browsers to this device, and lists the browsers bound so far.
using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Extension;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

public sealed partial class ExtensionSettings(LibraryModel library, bool autoCheckUpdate = false) : SettingsSubpage
{
    ExtensionClients? _state;
    ExtensionManagedStatus? _managed;
    ExtensionUpdateCheck? _updateCheck;
    bool _busy;
    bool _didAutoCheck;
    string? _error;
    HashSet<string> _before = [];
    Microsoft.UI.Dispatching.DispatcherQueueTimer? _poll;

    public override string Title => L("ext.title");

    /// The settings row's detail: how many browsers are bound.
    public static string Summary()
    {
        try
        {
            var n = TlCore.ExtensionClients().Clients.Count;
            return n == 0 ? L("ext.state.none") : L("ext.state.count", n.ToString());
        }
        catch { return L("ext.state.none"); }
    }

    void Load()
    {
        try { _managed = TlCore.ExtensionManagedStatus(); } catch { }
        try
        {
            var s = TlCore.ExtensionClients();
            if (_state?.Pairing != null && s.Pairing == null)
            {
                _poll?.Stop();
                var added = s.Clients.FirstOrDefault(c => !_before.Contains(c.Id));
                if (added != null) Dialogs.Toast(W, L("ext.code.done", added.Name));
            }
            _state = s;
            _error = null;
        }
        catch (Exception e) { _error = e.Message; }
    }

    public override void Build()
    {
        Load();
        Clear();
        _ = library;
        Add(new TextBlock { Text = L("ext.intro"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(2, 8, 0, 8) });
        BuildManagedSection();
        if (_state?.Pairing is { } p)
        {
            var code = p.Code.Length > 3 ? $"{p.Code[..3]} {p.Code[3..]}" : p.Code;
            var copy = new Button { Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { new FontIcon { Glyph = "", FontSize = 14 }, new TextBlock { Text = L("ext.code.copy") } } } };
            copy.Click += (_, _) =>
            {
                var dp = new Windows.ApplicationModel.DataTransfer.DataPackage();
                dp.SetText(p.Link);
                Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(dp);
                Dialogs.Toast(W, L("ext.code.copied"));
            };
            Add(new Border
            {
                Padding = new Thickness(20), CornerRadius = new CornerRadius(8),
                Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
                BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], BorderThickness = new Thickness(1),
                Child = new StackPanel
                {
                    Spacing = 12,
                    Children =
                    {
                        new TextBlock { Text = L("ext.code.title"), Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] },
                        new TextBlock { Text = code, Style = (Style)Application.Current.Resources["DisplayTextBlockStyle"], CharacterSpacing = 200, HorizontalAlignment = HorizontalAlignment.Center, IsTextSelectionEnabled = true },
                        new TextBlock { Text = L("ext.code.howto"), TextWrapping = TextWrapping.Wrap },
                        new TextBox { Text = p.Link, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas") },
                        new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } }, Children = { new TextBlock { Text = L("ext.code.expires"), Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], VerticalAlignment = VerticalAlignment.Center }, Col(copy, 1) } },
                    },
                },
            });
        }
        else
        {
            var bind = Action(L("ext.bind"), null, "", Bind);
            bind.IsEnabled = Receiver.Port != null;
        }
        if (_error != null) Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Message = _error });
        Header(L("ext.clients"));
        var clients = _state?.Clients ?? [];
        if (clients.Count == 0) Card(L("ext.state.none"));
        foreach (var c in clients)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            if (_managed?.Installed == true)
            {
                if (_updateCheck is { HasUpdate: true } u)
                {
                    var upd = new Button
                    {
                        Content = L("ext.managed.update", u.Latest),
                        Style = (Style)Application.Current.Resources["AccentButtonStyle"],
                        IsEnabled = !_busy,
                    };
                    upd.Click += (_, _) => _ = RunInstall(updating: true);
                    actions.Children.Add(upd);
                }
                else
                {
                    var chk = new Button { Content = L("ext.managed.checkUpdate"), IsEnabled = !_busy };
                    chk.Click += (_, _) => _ = RunCheck();
                    actions.Children.Add(chk);
                }
            }
            var remove = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 } };
            ToolTipService.SetToolTip(remove, L("ext.remove.confirm"));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(remove, L("ext.remove.confirm"));
            remove.Click += (_, _) => _ = Remove(c);
            actions.Children.Add(remove);
            Card(c.Name, L("ext.client.detail", Date(c.Added), Date(c.Seen)), "", actions);
        }
        Footer(Receiver.Port != null ? L("ext.footer.desktop", Receiver.Port.ToString()) : L("ext.unavailable", Receiver.Problem ?? ""));

        if (autoCheckUpdate && !_didAutoCheck && _managed?.Installed == true)
        {
            _didAutoCheck = true;
            _ = RunCheck();
        }
    }

    void BuildManagedSection()
    {
        Header(L("ext.managed.title"));
        if (_managed is { Installed: true } m)
        {
            Button action;
            if (_updateCheck is { HasUpdate: true } u)
            {
                action = new Button
                {
                    Content = L("ext.managed.update", u.Latest),
                    Style = (Style)Application.Current.Resources["AccentButtonStyle"],
                    IsEnabled = !_busy,
                };
                action.Click += (_, _) => _ = RunInstall(updating: true);
            }
            else
            {
                action = new Button { Content = _busy ? L("ext.managed.checking") : L("ext.managed.checkUpdate"), IsEnabled = !_busy };
                action.Click += (_, _) => _ = RunCheck();
            }
            var desc = _updateCheck is { HasUpdate: true } upd ? L("ext.managed.updateReady", upd.Latest) : null;
            Card(L("ext.managed.version", m.Version ?? ""), desc, "", action);

            var openBtn = new Button { Content = L("ext.managed.openFolder") };
            openBtn.Click += (_, _) =>
            {
                try { Process.Start(new ProcessStartInfo("explorer.exe", m.Dir) { UseShellExecute = true }); }
                catch (Exception e) { Dialogs.Toast(W, e.Message); }
            };
            var copyBtn = new Button { Content = L("ext.managed.copyPath") };
            copyBtn.Click += (_, _) =>
            {
                var dp = new Windows.ApplicationModel.DataTransfer.DataPackage();
                dp.SetText(m.Dir);
                Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(dp);
                Dialogs.Toast(W, L("ext.managed.pathCopied"));
            };
            var btnRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { openBtn, copyBtn } };
            Add(new Border
            {
                Padding = new Thickness(16), CornerRadius = new CornerRadius(8),
                Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
                BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], BorderThickness = new Thickness(1),
                Child = new StackPanel
                {
                    Spacing = 10,
                    Children =
                    {
                        new TextBox { Text = m.Dir, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas") },
                        btnRow,
                        new TextBlock
                        {
                            Text = L("ext.managed.installGuide"),
                            TextWrapping = TextWrapping.Wrap,
                            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                        },
                    },
                },
            });
        }
        else
        {
            var dl = new Button
            {
                Content = L("ext.managed.download"),
                Style = (Style)Application.Current.Resources["AccentButtonStyle"],
                IsEnabled = !_busy,
            };
            dl.Click += (_, _) => _ = RunInstall(updating: false);
            Card(L("ext.managed.download"), L("ext.managed.notInstalled"), "", dl);
        }
    }

    async Task RunCheck()
    {
        if (_busy) return;
        _busy = true;
        _error = null;
        Build();
        try
        {
            var info = await TlCore.Run(() => TlCore.ExtensionManagedCheck(Updates.Repo));
            _updateCheck = info;
            _busy = false;
            Build();
            if (info.HasUpdate)
            {
                var choice = await Dialogs.Choose(
                    W,
                    L("ext.managed.prompt.title", info.Latest),
                    L("ext.managed.prompt.message", info.Current ?? ""),
                    L("ext.managed.updateNow"));
                if (choice == 0) await RunInstall(updating: true);
            }
            else
            {
                Dialogs.Toast(W, L("ext.managed.upToDate", info.Current ?? info.Latest));
            }
        }
        catch (Exception e)
        {
            _busy = false;
            _error = L("ext.managed.checkFailed", e.Message);
            Build();
        }
    }

    async Task RunInstall(bool updating)
    {
        if (_busy) return;
        _busy = true;
        _error = null;
        Build();
        var st = await Receiver.InstallManaged(W, updating);
        _busy = false;
        if (st != null)
        {
            _managed = st;
            _updateCheck = null;
        }
        Build();
    }

    static FrameworkElement Col(FrameworkElement e, int c) { Grid.SetColumn(e, c); return e; }
    static string Date(long seconds) => DateTimeOffset.FromUnixTimeSeconds(seconds).LocalDateTime.ToString("yyyy-MM-dd HH:mm");

    void Bind()
    {
        try
        {
            _before = [.. (_state?.Clients ?? []).Select(c => c.Id)];
            TlCore.ExtensionPairBegin();
            _poll?.Stop();
            _poll = DispatcherQueue.CreateTimer();
            _poll.Interval = TimeSpan.FromMilliseconds(1500);
            _poll.Tick += (_, _) => Build();
            _poll.Start();
        }
        catch (Exception e) { _error = e.Message; }
        Build();
    }

    async Task Remove(ExtensionClient c)
    {
        if (!await Dialogs.Confirm(W, L("ext.remove.title", c.Name), L("ext.remove.message"), L("ext.remove.confirm"))) return;
        try { TlCore.ExtensionRemove(c.Id); } catch (Exception e) { _error = e.Message; }
        Build();
    }

    public override void Closed()
    {
        _poll?.Stop();
        if (_state?.Pairing != null) { try { TlCore.ExtensionPairCancel(); } catch { } }
    }
}
