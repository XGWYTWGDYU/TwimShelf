// Pure SVG + CSS animated stage scenes for WelcomeWindow (rendered in WebView2).
// Mirrors the real Windows 11 TwimShelf layout: Mica top bar (☰ + title, no app icon, no divider),
// Fluent NavigationView sidebar (vertical left accent pill, 设置 pinned at bottom), rounded content
// card, and Browse's floating capsule search bar with [🕒 ☷ ⬇ 🔀] buttons.
using System.Net;
using static TwimShelf.Services.Strings;

namespace TwimShelf;

static class WelcomeSvg
{
    public static string Html(int page, bool dark)
    {
        var stageBg = dark ? "rgba(255,255,255,0.05)" : "rgba(255,255,255,0.78)";
        var stageLine = dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.08)";
        var mica = dark ? "#18181b" : "#f3f4f6";
        var card = dark ? "#202024" : "#ffffff";
        var cardSub = dark ? "#28282d" : "#f7f8fa";
        var line = dark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.08)";
        var fg = dark ? "#f4f4f5" : "#18181b";
        var fg2 = dark ? "#a1a1aa" : "#646770";
        var fg3 = dark ? "#71717a" : "#9ca3af";
        var pillBg = dark ? "rgba(255,255,255,0.08)" : "#ffffff";

        var browse = E(L("place.browse"));
        var photos = E(L("place.photos"));
        var videos = E(L("place.videos"));
        var folders = E(L("place.folders"));
        var settings = E(L("place.settings"));
        var aiLabel = E(L("welcome.p5.chip.ai"));
        var mineLabel = E(L("welcome.p5.chip.mine"));
        var commonLabel = E(L("welcome.p5.chip.common"));

        var (css, body) = page switch
        {
            0 => Page1Shuffle(dark, mica, card, cardSub, line, fg, fg2, fg3, pillBg, browse, photos, videos, folders, settings),
            1 => Page2GridZoom(dark, mica, card, line, fg, fg2, browse, photos, videos, folders, settings),
            2 => Page3Download(dark, mica, card, cardSub, line, fg, fg2, fg3, pillBg, browse, photos, videos, folders, settings),
            3 => Page4AIModels(dark, mica, card, cardSub, line, fg, fg2, fg3, browse, photos, videos, folders, settings),
            4 => Page5TagTrio(dark, card, line, fg2, aiLabel, mineLabel, commonLabel),
            5 => Page6Search(dark, mica, card, cardSub, line, fg, fg2, fg3, pillBg, browse, photos, videos, folders, settings, aiLabel, videos, folders),
            6 => Page7LanSync(dark, card, line, fg2),
            _ => Page8ImportExport(dark, card, line, fg2),
        };

        return $$"""
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          * { box-sizing: border-box; user-select: none; -webkit-user-select: none; }
          html, body {
            margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden;
            background: transparent;
            font-family: "Segoe UI Variable", "Segoe UI", "Microsoft YaHei UI", sans-serif;
          }
          svg { display: block; width: 100%; height: 100%; }
          {{css}}
        </style>
        </head>
        <body>
        <svg viewBox="0 0 644 294" xmlns="http://www.w3.org/2000/svg">
          <rect x="1" y="1" width="642" height="292" rx="18" fill="{{stageBg}}" stroke="{{stageLine}}" stroke-width="1"/>
          {{body}}
        </svg>
        </body>
        </html>
        """;
    }

    static string E(string s) => WebUtility.HtmlEncode(s);

    // Real Windows 11 TwimShelf shell: Mica background, ☰ + title on top-left (NO app icon, NO divider line),
    // − □ × on top-right, NavigationView sidebar on left, rounded content card on right.
    static string WinShell(
        bool dark, string mica, string card, string line, string fg, string fg2,
        string activeNav, string titleText, string accent,
        string browse, string photos, string videos, string folders, string settings,
        string topRightControls, string content)
    {
        var hoverFill = dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.045)";
        var selFill = dark ? "rgba(255,255,255,0.09)" : "#ffffff";

        string NavRow(string key, string label, int y, string iconPath)
        {
            var on = key == activeNav;
            var pill = on ? $"""
              <rect x="36" y="{y}" width="104" height="24" rx="5" fill="{selFill}" stroke="{line}" stroke-width="0.7"/>
              <rect x="36" y="{y + 5}" width="3" height="14" rx="1.5" fill="{accent}"/>
            """ : "";
            var ic = on ? accent : fg2;
            var tc = on ? fg : fg2;
            var fw = on ? "600" : "400";
            return $"""
              {pill}
              <g transform="translate(46,{y + 6})" fill="none" stroke="{ic}" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round">{iconPath}</g>
              <text x="64" y="{y + 15.5}" font-size="10.5" font-weight="{fw}" fill="{tc}">{label}</text>
            """;
        }

        return $$"""
        <defs>
          <filter id="winShadow" x="-6%" y="-6%" width="112%" height="116%">
            <feDropShadow dx="0" dy="5" stdDeviation="7" flood-color="#000000" flood-opacity="{{(dark ? "0.36" : "0.10")}}"/>
          </filter>
          <clipPath id="winClip"><rect x="28" y="14" width="588" height="266" rx="10"/></clipPath>
          <clipPath id="paneClip"><rect x="148" y="48" width="460" height="224" rx="10"/></clipPath>
        </defs>

        <g filter="url(#winShadow)">
          <rect x="28" y="14" width="588" height="266" rx="10" fill="{{mica}}" stroke="{{line}}" stroke-width="1"/>
        </g>

        <g clip-path="url(#winClip)">
          <!-- Mica TitleBar: ONLY ☰ + page title on left, optional right commands, − □ × on right (NO app icon, NO bottom line) -->
          <g transform="translate(42,26)" stroke="{{fg2}}" stroke-width="1.35" stroke-linecap="round">
            <line x1="0" y1="1.5" x2="11" y2="1.5"/>
            <line x1="0" y1="5.5" x2="11" y2="5.5"/>
            <line x1="0" y1="9.5" x2="11" y2="9.5"/>
          </g>
          <text x="64" y="34.5" font-size="11.5" font-weight="600" fill="{{fg}}">{{titleText}}</text>

          {{topRightControls}}

          <!-- Windows Caption Buttons: − □ × -->
          <g stroke="{{fg2}}" stroke-width="1.15" fill="none" stroke-linecap="round">
            <line x1="548" y1="31" x2="556" y2="31"/>
            <rect x="572" y="27" width="8" height="8" rx="1"/>
            <line x1="596" y1="27" x2="604" y2="35"/>
            <line x1="604" y1="27" x2="596" y2="35"/>
          </g>

          <!-- NavigationView Sidebar (Mica) -->
          {{NavRow("browse", browse, 54, "<rect x='1' y='1' width='4.5' height='4.5' rx='1'/><rect x='7' y='1' width='4.5' height='4.5' rx='1'/><rect x='1' y='7' width='4.5' height='4.5' rx='1'/><rect x='7' y='7' width='4.5' height='4.5' rx='1'/>")}}
          {{NavRow("photos", photos, 84, "<rect x='1' y='2' width='10.5' height='8.5' rx='1.5'/><circle cx='4.2' cy='5' r='1' fill='currentColor'/><path d='M2 9.5l3-2.5 2.2 1.8 1.8-1.4 2 2.1'/>")}}
          {{NavRow("videos", videos, 114, "<rect x='1' y='2.5' width='7.5' height='7.5' rx='1.5'/><path d='M8.5 5l3-1.8v6.1l-3-1.8z'/>")}}
          {{NavRow("folders", folders, 144, "<path d='M1 3.5a1.2 1.2 0 0 1 1.2-1.2h3l1.3 1.4h4a1.2 1.2 0 0 1 1.2 1.2v5a1.2 1.2 0 0 1-1.2 1.2H2.2A1.2 1.2 0 0 1 1 9.9z'/>")}}
          {{NavRow("settings", settings, 244, "<circle cx='6.2' cy='6.2' r='2.2'/><path d='M6.2 1.5v1.4M6.2 9.5v1.4M1.5 6.2h1.4M9.5 6.2h1.4M2.9 2.9l1 1M8.5 8.5l1 1M9.5 2.9l-1 1M3.9 8.5l-1 1'/>")}}

          <!-- Rounded Content Card Container -->
          <rect x="148" y="48" width="460" height="224" rx="10" fill="{{card}}" stroke="{{line}}" stroke-width="0.9"/>
          <g clip-path="url(#paneClip)">
            {{content}}
          </g>
        </g>
        """;
    }

    // Real Browse floating capsule bar: [🔍 search...] + 4 circle buttons [🕒] [☷] [⬇] [🔀]
    // Centered in content pane (x=148..608, center=378).
    // Bar width = 338 (x=209..547): capsule (x=209..419, w=210) + 4 circles (centers at 439, 467, 495, 523)
    static string BrowseCapsuleBar(bool dark, string pillBg, string line, string fg3, string activeBtn, string activeAccent, string extraTokenSvg = "")
    {
        string CircleBtn(string id, int cx, string cls, string iconSvg)
        {
            var on = id == activeBtn;
            var bg = on ? activeAccent : pillBg;
            var stroke = on ? activeAccent : line;
            var ic = on ? "#ffffff" : (dark ? "#d4d4d8" : "#52525b");
            return $"""
              <g class="{cls}" style="transform-origin:{cx}px 70px">
                <circle cx="{cx}" cy="70" r="11.5" fill="{bg}" stroke="{stroke}" stroke-width="0.9"/>
                <g transform="translate({cx - 6},64)" fill="none" stroke="{ic}" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round">{iconSvg}</g>
              </g>
            """;
        }

        return $$"""
        <g>
          <rect x="209" y="57" width="210" height="26" rx="13" fill="{{pillBg}}" stroke="{{line}}" stroke-width="0.9"/>
          <g transform="translate(220,64)" fill="none" stroke="{{fg3}}" stroke-width="1.35" stroke-linecap="round">
            <circle cx="5" cy="5" r="4"/>
            <line x1="8" y1="8" x2="11" y2="11"/>
          </g>
          {{(string.IsNullOrEmpty(extraTokenSvg)
              ? $"""<rect x="239" y="67.5" width="110" height="5" rx="2.5" fill="{line}"/>"""
              : extraTokenSvg)}}
          {{CircleBtn("clock", 439, "btn-clock", "<circle cx='6' cy='6' r='4.8'/><path d='M6 3.5v2.7l1.8 1.1'/>")}}
          {{CircleBtn("group", 467, "btn-group", "<rect x='1.5' y='2' width='9' height='3' rx='0.8'/><rect x='1.5' y='7' width='9' height='3' rx='0.8'/>")}}
          {{CircleBtn("dl", 495, "btn-dl", "<path d='M6 1.8v6.4M3.5 5.8L6 8.4l2.5-2.6'/><path d='M2 10.2h8'/>")}}
          {{CircleBtn("shuffle", 523, "btn-shuffle", "<path d='M1.5 3.5h2.2l4.6 5h2.2M1.5 8.5h2.2l1.6-1.8M7.2 4.7l1.1-1.2h2.2'/><path d='M9 2l1.7 1.5L9 5M9 7l1.7 1.5L9 10'/>")}}
        </g>
        """;
    }

    // ---- Page 1: Random Browse + Reshuffle ----------------------------------------------------

    static (string css, string body) Page1Shuffle(bool dark, string mica, string card, string cardSub, string line, string fg, string fg2, string fg3, string pillBg, string browse, string photos, string videos, string folders, string settings)
    {
        const string accent = "#f97316";
        var css = """
          .btn-shuffle { animation: sBtn 6s ease-in-out infinite; }
          @keyframes sBtn { 0%,24%,34%,58%,68%,100% { transform: scale(1); } 28%,62% { transform: scale(0.84); } }
          .c1 { animation: p1c1 6s cubic-bezier(.2,.8,.2,1) infinite; }
          .c2 { animation: p1c2 6s cubic-bezier(.2,.8,.2,1) infinite; }
          .c3 { animation: p1c3 6s cubic-bezier(.2,.8,.2,1) infinite; }
          .c4 { animation: p1c4 6s cubic-bezier(.2,.8,.2,1) infinite; }
          .c5 { animation: p1c5 6s cubic-bezier(.2,.8,.2,1) infinite; }
          .c6 { animation: p1c6 6s cubic-bezier(.2,.8,.2,1) infinite; }
          @keyframes p1c1 { 0%,24% { transform: translate(164px,95px); } 33%,58% { transform: translate(310px,176px); } 67%,100% { transform: translate(456px,95px); } }
          @keyframes p1c2 { 0%,24% { transform: translate(310px,95px); } 33%,58% { transform: translate(456px,95px); } 67%,100% { transform: translate(164px,178px); } }
          @keyframes p1c3 { 0%,24% { transform: translate(456px,95px); } 33%,58% { transform: translate(164px,95px); } 67%,100% { transform: translate(310px,95px); } }
          @keyframes p1c4 { 0%,24% { transform: translate(164px,185px); } 33%,58% { transform: translate(310px,95px); } 67%,100% { transform: translate(456px,178px); } }
          @keyframes p1c5 { 0%,24% { transform: translate(310px,168px); } 33%,58% { transform: translate(456px,178px); } 67%,100% { transform: translate(164px,95px); } }
          @keyframes p1c6 { 0%,24% { transform: translate(456px,178px); } 33%,58% { transform: translate(164px,182px); } 67%,100% { transform: translate(310px,178px); } }
        """;

        string Card(string cls, int h, string tint, string badge) => $"""
          <g class="{cls}">
            <rect width="136" height="{h}" rx="8" fill="{cardSub}" stroke="{line}" stroke-width="0.9"/>
            <rect width="136" height="{h - 18}" rx="8" fill="{tint}" opacity="0.22"/>
            <rect y="{h - 22}" width="136" height="4" fill="{tint}" opacity="0.22"/>
            <rect x="8" y="{h - 11}" width="54" height="4" rx="2" fill="{line}"/>
            {badge}
          </g>
        """;

        var content = BrowseCapsuleBar(dark, pillBg, line, fg3, "shuffle", accent) +
            Card("c1", 80, "#f97316", "<circle cx='122' cy='14' r='5' fill='#f97316' opacity='0.5'/>") +
            Card("c2", 64, "#ec4899", "<polygon points='120,10 127,14 120,18' fill='#ec4899' opacity='0.65'/>") +
            Card("c3", 74, "#6366f1", "") +
            Card("c4", 72, "#14b8a6", "<polygon points='120,10 127,14 120,18' fill='#14b8a6' opacity='0.65'/>") +
            Card("c5", 82, "#f59e0b", "") +
            Card("c6", 74, "#8b5cf6", "");

        var body = WinShell(dark, mica, card, line, fg, fg2, "browse", browse, accent, browse, photos, videos, folders, settings, "", content);
        return (css, body);
    }

    // ---- Page 2: Album Grid Zoom (zoom buttons in Mica titlebar right, just like real MainWindow) ----

    static (string css, string body) Page2GridZoom(bool dark, string mica, string card, string line, string fg, string fg2, string browse, string photos, string videos, string folders, string settings)
    {
        const string accent = "#0078d4";
        var css = """
          .g-dense { animation: gFadeA 5.4s ease-in-out infinite; }
          .g-med   { animation: gFadeB 5.4s ease-in-out infinite; }
          .g-large { animation: gFadeC 5.4s ease-in-out infinite; }
          .z-out   { animation: zOut 5.4s ease-in-out infinite; }
          .z-in    { animation: zIn 5.4s ease-in-out infinite; }
          @keyframes gFadeA { 0%,28% { opacity:1; } 34%,94% { opacity:0; } 100% { opacity:1; } }
          @keyframes gFadeB { 0%,28% { opacity:0; } 34%,61% { opacity:1; } 67%,100% { opacity:0; } }
          @keyframes gFadeC { 0%,61% { opacity:0; } 67%,94% { opacity:1; } 100% { opacity:0; } }
          @keyframes zOut { 0%,28% { opacity:1; } 34%,100% { opacity:0.35; } }
          @keyframes zIn  { 0%,61% { opacity:0.35; } 67%,94% { opacity:1; } 100% { opacity:0.35; } }
        """;

        string GridLayer(string cls, int cols, int rows)
        {
            const double gap = 4, w = 436;
            var side = (w - gap * (cols - 1)) / cols;
            var tints = new[] { "#0078d4", "#6366f1", "#06b6d4", "#14b8a6", "#8b5cf6", "#10b981" };
            var ar = rows / 2;
            var ac = cols / 2;
            var sb = new System.Text.StringBuilder($"<g class=\"{cls}\">");
            for (var r = 0; r < rows; r++)
                for (var c = 0; c < cols; c++)
                {
                    var x = 160 + c * (side + gap);
                    var y = 60 + r * (side + gap);
                    var anchor = r == ar && c == ac;
                    var fill = anchor ? accent : tints[(r * 7 + c * 3) % tints.Length];
                    var op = anchor ? "1" : (dark ? "0.28" : "0.20");
                    sb.Append($"<rect x=\"{x:F1}\" y=\"{y:F1}\" width=\"{side:F1}\" height=\"{side:F1}\" rx=\"4\" fill=\"{fill}\" opacity=\"{op}\"/>");
                    if (anchor)
                    {
                        var cx = x + side / 2;
                        var cy = y + side / 2;
                        sb.Append($"<rect x=\"{cx - 8:F1}\" y=\"{cy - 8:F1}\" width=\"16\" height=\"16\" rx=\"3\" fill=\"none\" stroke=\"#fff\" stroke-width=\"1.8\"/>");
                    }
                }
            sb.Append("</g>");
            return sb.ToString();
        }

        // Real GridPage puts FloatingBar (zoom buttons) floating at the top-center of the grid pane
        var floatingZoom = $"""
          <g>
            <rect x="342" y="55" width="72" height="28" rx="14" fill="{card}" stroke="{line}" stroke-width="0.9"/>
            <g class="z-out">
              <circle cx="364" cy="69" r="10" fill="{(dark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.06)")}"/>
              <circle cx="363" cy="68" r="3.8" fill="none" stroke="{fg2}" stroke-width="1.2"/>
              <line x1="361.5" y1="68" x2="364.5" y2="68" stroke="{fg2}" stroke-width="1.2"/>
              <line x1="366" y1="71" x2="368" y2="73" stroke="{fg2}" stroke-width="1.2"/>
            </g>
            <g class="z-in">
              <circle cx="392" cy="69" r="10" fill="{accent}"/>
              <circle cx="391" cy="68" r="3.8" fill="none" stroke="#fff" stroke-width="1.2"/>
              <line x1="389.5" y1="68" x2="392.5" y2="68" stroke="#fff" stroke-width="1.2"/>
              <line x1="391" y1="66.5" x2="391" y2="69.5" stroke="#fff" stroke-width="1.2"/>
              <line x1="394" y1="71" x2="396" y2="73" stroke="#fff" stroke-width="1.2"/>
            </g>
          </g>
        """;

        var content = GridLayer("g-dense", 6, 3) + GridLayer("g-med", 4, 2) + GridLayer("g-large", 2, 1) + floatingZoom;
        return (css, WinShell(dark, mica, card, line, fg, fg2, "photos", photos, accent, browse, photos, videos, folders, settings, "", content));
    }

    // ---- Page 3: Quick Download (caret centered at cx=495) + Settings JSON Batch Import ----

    static (string css, string body) Page3Download(bool dark, string mica, string card, string cardSub, string line, string fg, string fg2, string fg3, string pillBg, string browse, string photos, string videos, string folders, string settings)
    {
        const string accent = "#06b6d4";
        var css = """
          .p3-a { animation: p3A 6.4s ease-in-out infinite; }
          .p3-b { animation: p3B 6.4s ease-in-out infinite; }
          .p3-pop { transform-origin: 495px 86px; animation: p3Pop 6.4s ease-in-out infinite; }
          .p3-bar { animation: p3Bar 6.4s ease-in-out infinite; }
          @keyframes p3A { 0%,47% { opacity:1; } 52%,95% { opacity:0; } 100% { opacity:1; } }
          @keyframes p3B { 0%,47% { opacity:0; } 52%,95% { opacity:1; } 100% { opacity:0; } }
          @keyframes p3Pop { 0%,5% { opacity:0; transform:scale(0.92); } 12%,45% { opacity:1; transform:scale(1); } 50%,100% { opacity:0; } }
          @keyframes p3Bar { 52% { width:60px; } 85%,95% { width:340px; } }
        """;

        var browseContent = BrowseCapsuleBar(dark, pillBg, line, fg3, "dl", accent) +
            $"""
            <rect x="164" y="96" width="136" height="72" rx="8" fill="{cardSub}" opacity="0.65"/>
            <rect x="310" y="96" width="136" height="72" rx="8" fill="{cardSub}" opacity="0.65"/>
            <rect x="456" y="96" width="136" height="72" rx="8" fill="{cardSub}" opacity="0.65"/>
            <rect x="164" y="178" width="136" height="72" rx="8" fill="{cardSub}" opacity="0.65"/>
            <rect x="310" y="178" width="136" height="72" rx="8" fill="{cardSub}" opacity="0.65"/>
            <rect x="456" y="178" width="136" height="72" rx="8" fill="{cardSub}" opacity="0.65"/>

            <!-- Quick Download Popover centered at cx=495 (directly under the ⬇ circle button!) -->
            <g class="p3-pop">
              <polygon points="489,93 495,86 501,93" fill="{accent}"/>
              <rect x="366" y="93" width="224" height="122" rx="11" fill="{card}" stroke="{accent}" stroke-width="1.2"/>
              <circle cx="384" cy="110" r="6.5" fill="{accent}"/>
              <path d="M384 106.5v5.5M381.8 110l2.2 2.2 2.2-2.2" fill="none" stroke="#fff" stroke-width="1.2" stroke-linecap="round"/>
              <rect x="396" y="107.5" width="76" height="5" rx="2.5" fill="{line}"/>
              <rect x="378" y="124" width="200" height="22" rx="6" fill="{cardSub}"/>
              <rect x="388" y="132.5" width="124" height="5" rx="2.5" fill="{line}"/>
              <circle cx="564" cy="135" r="5.5" fill="#10b981"/>
              <rect x="378" y="152" width="200" height="22" rx="6" fill="{cardSub}"/>
              <rect x="388" y="160.5" width="96" height="5" rx="2.5" fill="{line}"/>
              <circle cx="564" cy="163" r="5.5" fill="#10b981"/>
              <rect x="518" y="182" width="60" height="22" rx="11" fill="#10b981"/>
              <path d="M532 193l3 3 5.5-5.5" fill="none" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>
              <rect x="545" y="191" width="22" height="4" rx="2" fill="#fff" opacity="0.88"/>
            </g>
            """;

        var settingsContent = $"""
          <rect x="196" y="88" width="364" height="68" rx="11" fill="{accent}" opacity="0.10" stroke="{accent}" stroke-width="1.2" stroke-dasharray="5 4"/>
          <rect x="216" y="106" width="28" height="32" rx="5" fill="{accent}" opacity="0.22"/>
          <text x="256" y="119" font-size="12" font-weight="600" fill="{fg}">bookmarks.json</text>
          <rect x="256" y="128" width="126" height="5" rx="2.5" fill="{line}"/>
          <circle cx="532" cy="122" r="10" fill="#10b981"/>
          <path d="M527.5 122l3 3 6-6" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/>
          <rect x="196" y="176" width="364" height="7" rx="3.5" fill="{line}"/>
          <rect class="p3-bar" x="196" y="176" width="60" height="7" rx="3.5" fill="#10b981"/>
          <rect x="242" y="202" width="84" height="22" rx="11" fill="{accent}" opacity="0.16"/>
          <rect x="336" y="202" width="84" height="22" rx="11" fill="{accent}" opacity="0.16"/>
          <rect x="430" y="202" width="84" height="22" rx="11" fill="{accent}" opacity="0.16"/>
        """;

        var body =
            $"<g class=\"p3-a\">{WinShell(dark, mica, card, line, fg, fg2, "browse", browse, accent, browse, photos, videos, folders, settings, "", browseContent)}</g>" +
            $"<g class=\"p3-b\">{WinShell(dark, mica, card, line, fg, fg2, "settings", settings, accent, browse, photos, videos, folders, settings, "", settingsContent)}</g>";
        return (css, body);
    }

    // ---- Page 4: AI Model Download -> Scan -> Tags --------------------------------------------

    static (string css, string body) Page4AIModels(bool dark, string mica, string card, string cardSub, string line, string fg, string fg2, string fg3, string browse, string photos, string videos, string folders, string settings)
    {
        const string accent = "#8b5cf6";
        var css = """
          .mbar { animation: mBar 4.8s ease-in-out infinite; }
          .scan { animation: mScan 4.8s ease-in-out infinite; }
          .mtag { animation: mTag 4.8s ease-in-out infinite; }
          @keyframes mBar { 0% { width: 32px; } 45%,100% { width: 170px; } }
          @keyframes mScan { 0%,40% { opacity:0; transform:translateY(0); } 50% { opacity:0.9; } 72% { opacity:0.9; transform:translateY(76px); } 78%,100% { opacity:0; } }
          @keyframes mTag { 0%,68% { opacity:0.15; transform:scale(0.85); } 78%,96% { opacity:1; transform:scale(1); } 100% { opacity:0.15; } }
        """;

        var content = $"""
          <rect x="168" y="76" width="204" height="168" rx="12" fill="{cardSub}" stroke="{accent}" stroke-opacity="0.45" stroke-width="1"/>
          <rect x="184" y="96" width="28" height="28" rx="8" fill="{accent}" opacity="0.22"/>
          <text x="198" y="114.5" text-anchor="middle" font-size="13" fill="{accent}">✦</text>
          <text x="220" y="108" font-size="11" font-weight="600" fill="{fg}">VLM · Q4_K_M</text>
          <rect x="220" y="115" width="76" height="4.5" rx="2.25" fill="{line}"/>
          <rect x="184" y="144" width="170" height="6" rx="3" fill="{line}"/>
          <rect class="mbar" x="184" y="144" width="32" height="6" rx="3" fill="{accent}"/>
          <rect x="184" y="166" width="170" height="58" rx="8" fill="{card}" stroke="{line}" stroke-width="0.8"/>
          <rect x="196" y="180" width="90" height="5" rx="2.5" fill="{line}"/>
          <rect x="196" y="194" width="64" height="4.5" rx="2.25" fill="{line}"/>
          <rect x="314" y="182" width="28" height="15" rx="7.5" fill="{accent}"/>
          <circle cx="334.5" cy="189.5" r="5.5" fill="#fff"/>

          <rect x="386" y="76" width="202" height="168" rx="12" fill="{cardSub}" stroke="{line}" stroke-width="1"/>
          <rect x="400" y="92" width="174" height="92" rx="9" fill="{accent}" opacity="0.16"/>
          <rect class="scan" x="400" y="94" width="174" height="12" fill="{accent}" opacity="0.45"/>
          <g class="mtag" style="transform-origin:487px 212px">
            <rect x="400" y="200" width="52" height="22" rx="11" fill="{accent}" opacity="0.20" stroke="{accent}" stroke-opacity="0.5" stroke-width="0.9"/>
            <text x="411" y="214.5" font-size="10" fill="{accent}">✦</text>
            <rect x="422" y="209" width="21" height="4" rx="2" fill="{accent}" opacity="0.7"/>
            <rect x="458" y="200" width="56" height="22" rx="11" fill="{accent}" opacity="0.20" stroke="{accent}" stroke-opacity="0.5" stroke-width="0.9"/>
            <text x="469" y="214.5" font-size="10" fill="{accent}">✦</text>
            <rect x="480" y="209" width="25" height="4" rx="2" fill="{accent}" opacity="0.7"/>
            <rect x="520" y="200" width="52" height="22" rx="11" fill="{accent}" opacity="0.20" stroke="{accent}" stroke-opacity="0.5" stroke-width="0.9"/>
            <text x="531" y="214.5" font-size="10" fill="{accent}">✦</text>
            <rect x="542" y="209" width="21" height="4" rx="2" fill="{accent}" opacity="0.7"/>
          </g>
        """;

        return (css, WinShell(dark, mica, card, line, fg, fg2, "settings", settings, accent, browse, photos, videos, folders, settings, "", content));
    }

    // ---- Page 5: Three Tag Types (Electron-parity Post Card + Tag Strip + 3 Legend Chips) -----

    static (string css, string body) Page5TagTrio(bool dark, string card, string line, string fg2, string ai, string mine, string common)
    {
        var mediaBg = dark ? "rgba(99,102,241,0.18)" : "rgba(99,102,241,0.10)";
        var plusBg = dark ? "rgba(255,255,255,0.09)" : "rgba(0,0,0,0.06)";
        var css = """
          .p5-ai    { animation: p5Ai 5.4s ease-in-out infinite; }
          .p5-com   { animation: p5Com 5.4s ease-in-out infinite; }
          .p5-mine  { animation: p5Mine 5.4s ease-in-out infinite; transform-origin: 292px 181px; }
          .p5-plus  { animation: p5Plus 5.4s ease-in-out infinite; }
          .p5-lg0   { animation: p5Lg0 5.4s ease-in-out infinite; transform-origin: 215px 246px; }
          .p5-lg1   { animation: p5Lg1 5.4s ease-in-out infinite; transform-origin: 322px 246px; }
          .p5-lg2   { animation: p5Lg2 5.4s ease-in-out infinite; transform-origin: 429px 246px; }
          @keyframes p5Ai   { 0%,63% { opacity:1; } 68%,96% { opacity:0; } 100% { opacity:1; } }
          @keyframes p5Com  { 0%,63% { opacity:0; } 68%,96% { opacity:1; } 100% { opacity:0; } }
          @keyframes p5Mine { 0%,29% { opacity:0; transform:scale(0.84); } 36%,96% { opacity:1; transform:scale(1); } 100% { opacity:0; transform:scale(0.84); } }
          @keyframes p5Plus { 0%,29% { transform:translateX(0); } 36%,96% { transform:translateX(78px); } 100% { transform:translateX(0); } }
          @keyframes p5Lg0  { 0%,29% { opacity:1; transform:scale(1.06); } 36%,100% { opacity:0.65; transform:scale(0.96); } }
          @keyframes p5Lg1  { 0%,29% { opacity:0.65; transform:scale(0.96); } 36%,63% { opacity:1; transform:scale(1.06); } 68%,100% { opacity:0.65; transform:scale(0.96); } }
          @keyframes p5Lg2  { 0%,63% { opacity:0.65; transform:scale(0.96); } 68%,96% { opacity:1; transform:scale(1.06); } 100% { opacity:0.65; transform:scale(0.96); } }
        """;

        var body = $$"""
          <defs>
            <clipPath id="tagCardClip"><rect x="167" y="34" width="310" height="172" rx="14"/></clipPath>
          </defs>

          <!-- Media Post Card -->
          <rect x="167" y="34" width="310" height="172" rx="14" fill="{{card}}" stroke="{{line}}" stroke-width="1"/>
          <g clip-path="url(#tagCardClip)">
            <rect x="167" y="34" width="310" height="90" fill="{{mediaBg}}"/>
            <g transform="translate(310,67)" fill="none" stroke="{{fg2}}" stroke-opacity="0.45" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
              <rect x="2" y="3" width="20" height="16" rx="2.5"/><circle cx="8" cy="8.5" r="1.5"/><path d="M4 17l5-4.5 3.5 3 3-2.5 4.5 4"/>
            </g>
            <!-- Wireframe caption lines -->
            <rect x="183" y="138" width="84" height="6" rx="3" fill="{{line}}"/>
            <rect x="275" y="138" width="52" height="6" rx="3" fill="{{line}}" opacity="0.6"/>

            <!-- Tag Strip -->
            <g class="p5-ai">
              <rect x="183" y="162" width="62" height="24" rx="12" fill="#9333ea" fill-opacity="0.16" stroke="#9333ea" stroke-opacity="0.65" stroke-width="1.1"/>
              <text x="214" y="178" text-anchor="middle" font-size="11" font-weight="600" fill="#9333ea">✦ {{ai}}</text>
            </g>
            <g class="p5-com">
              <rect x="183" y="162" width="66" height="24" rx="12" fill="#16a34a" fill-opacity="0.16" stroke="#16a34a" stroke-opacity="0.65" stroke-width="1.1"/>
              <text x="216" y="178" text-anchor="middle" font-size="11" font-weight="600" fill="#16a34a">✓ {{common}}</text>
            </g>
            <g class="p5-mine">
              <rect x="255" y="162" width="72" height="24" rx="12" fill="#0a66ff" fill-opacity="0.16" stroke="#0a66ff" stroke-opacity="0.65" stroke-width="1.1"/>
              <text x="291" y="178" text-anchor="middle" font-size="11" font-weight="600" fill="#0a66ff">🏷 {{mine}}</text>
            </g>
            <g class="p5-plus">
              <circle cx="268" cy="174" r="11" fill="{{plusBg}}"/>
              <path d="M268 170v8M264 174h8" stroke="{{fg2}}" stroke-width="1.5" stroke-linecap="round"/>
            </g>
          </g>

          <!-- 3 Legend Chips Underneath -->
          <g class="p5-lg0">
            <rect x="169" y="232" width="92" height="28" rx="8" fill="#9333ea" fill-opacity="0.16" stroke="#9333ea" stroke-opacity="0.6" stroke-width="1.1"/>
            <text x="215" y="250" text-anchor="middle" font-size="11.5" font-weight="600" fill="#9333ea">✦ {{ai}}</text>
          </g>
          <g class="p5-lg1">
            <rect x="275" y="232" width="94" height="28" rx="8" fill="#0a66ff" fill-opacity="0.16" stroke="#0a66ff" stroke-opacity="0.6" stroke-width="1.1"/>
            <text x="322" y="250" text-anchor="middle" font-size="11.5" font-weight="600" fill="#0a66ff">🏷 {{mine}}</text>
          </g>
          <g class="p5-lg2">
            <rect x="383" y="232" width="92" height="28" rx="8" fill="#16a34a" fill-opacity="0.16" stroke="#16a34a" stroke-opacity="0.6" stroke-width="1.1"/>
            <text x="429" y="250" text-anchor="middle" font-size="11.5" font-weight="600" fill="#16a34a">✓ {{common}}</text>
          </g>
        """;
        return (css, body);
    }

    // ---- Page 6: Multi-Faceted Token Search inside real Browse capsule bar --------------------

    static (string css, string body) Page6Search(bool dark, string mica, string card, string cardSub, string line, string fg, string fg2, string fg3, string pillBg, string browse, string photos, string videos, string folders, string settings, string ai, string vid, string fld)
    {
        const string accent = "#6366f1";
        var css = """
          .tok2 { animation: tok2 4.8s ease-in-out infinite; }
          .tok3 { animation: tok3 4.8s ease-in-out infinite; }
          .sc-vid { animation: scV 4.8s ease-in-out infinite; }
          .sc-fld { animation: scF 4.8s ease-in-out infinite; }
          @keyframes tok2 { 0%,28% { opacity:0; } 34%,100% { opacity:1; } }
          @keyframes tok3 { 0%,60% { opacity:0; } 66%,100% { opacity:1; } }
          @keyframes scV  { 0%,28% { opacity:1; } 34%,100% { opacity:0.24; } }
          @keyframes scF  { 0%,60% { opacity:1; } 66%,100% { opacity:0.24; } }
        """;

        var tokensSvg = $"""
          <rect x="236" y="61.5" width="46" height="17" rx="8.5" fill="#a855f7" fill-opacity="0.20"/>
          <text x="259" y="73.5" text-anchor="middle" font-size="9.5" font-weight="600" fill="#a855f7">✦ {ai}</text>
          <g class="tok2">
            <rect x="286" y="61.5" width="48" height="17" rx="8.5" fill="{accent}" fill-opacity="0.20"/>
            <text x="310" y="73.5" text-anchor="middle" font-size="9.5" font-weight="600" fill="{accent}">{vid}</text>
          </g>
          <g class="tok3">
            <rect x="338" y="61.5" width="60" height="17" rx="8.5" fill="#ef4444" fill-opacity="0.20"/>
            <text x="368" y="73.5" text-anchor="middle" font-size="9.5" font-weight="600" fill="#ef4444">− {fld}</text>
          </g>
        """;

        string SCard(int x, int y, string cls, bool isVideo, bool isFolder, bool dim) => $"""
          <g class="{cls}" opacity="{(dim ? "0.24" : "1")}">
            <rect x="{x}" y="{y}" width="136" height="72" rx="9" fill="{accent}" fill-opacity="{(dim ? "0.05" : "0.14")}" stroke="{accent}" stroke-opacity="{(dim ? "0.2" : "0.65")}" stroke-width="1.1"/>
            <text x="{x + 68}" y="{y + 40}" text-anchor="middle" font-size="14" fill="{accent}">{(isVideo ? "▶" : "▣")}  ✦{(isFolder ? "  📁" : "")}</text>
          </g>
        """;

        var content = BrowseCapsuleBar(dark, pillBg, line, fg3, "", accent, tokensSvg) +
            SCard(164, 98, "", true, false, false) +
            SCard(310, 98, "sc-vid", false, false, false) +
            SCard(456, 98, "sc-fld", true, true, false) +
            SCard(164, 180, "", true, false, true) +
            SCard(310, 180, "", true, false, false) +
            SCard(456, 180, "sc-fld", true, true, false);

        return (css, WinShell(dark, mica, card, line, fg, fg2, "browse", browse, accent, browse, photos, videos, folders, settings, "", content));
    }

    // ---- Page 7: Local LAN Decentralized P2P Sync ---------------------------------------------

    static (string css, string body) Page7LanSync(bool dark, string card, string line, string fg2)
    {
        const string accent = "#14b8a6";
        var css = """
          .pkt1 { animation: pktA 2.4s linear infinite; }
          .pkt2 { animation: pktB 2.4s linear infinite; }
          .pkt3 { animation: pktC 2.4s linear infinite; }
          @keyframes pktA { 0% { transform:translate(322px,62px); } 100% { transform:translate(196px,210px); } }
          @keyframes pktB { 0% { transform:translate(196px,210px); } 100% { transform:translate(448px,210px); } }
          @keyframes pktC { 0% { transform:translate(448px,210px); } 100% { transform:translate(322px,62px); } }
        """;

        string Peer(int cx, int cy, string iconSvg) => $"""
          <rect x="{cx - 30}" y="{cy - 30}" width="60" height="60" rx="16" fill="{card}" stroke="{accent}" stroke-width="1.6"/>
          <g transform="translate({cx - 12},{cy - 12})" fill="none" stroke="{accent}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">{iconSvg}</g>
        """;

        var body = $$"""
          <line x1="322" y1="62" x2="196" y2="210" stroke="{{accent}}" stroke-opacity="0.45" stroke-width="1.8" stroke-dasharray="5 4"/>
          <line x1="196" y1="210" x2="448" y2="210" stroke="{{accent}}" stroke-opacity="0.45" stroke-width="1.8" stroke-dasharray="5 4"/>
          <line x1="448" y1="210" x2="322" y2="62" stroke="{{accent}}" stroke-opacity="0.45" stroke-width="1.8" stroke-dasharray="5 4"/>

          <circle class="pkt1" r="5" fill="{{accent}}"/>
          <circle class="pkt2" r="5" fill="{{accent}}"/>
          <circle class="pkt3" r="5" fill="{{accent}}"/>

          <rect x="278" y="142" width="88" height="24" rx="12" fill="{{accent}}" fill-opacity="0.16" stroke="{{accent}}" stroke-opacity="0.5" stroke-width="1"/>
          <text x="322" y="158" text-anchor="middle" font-size="11" font-weight="600" fill="{{accent}}">LAN · P2P</text>

          {{Peer(322, 62, "<rect x='2' y='3' width='20' height='14' rx='2'/><line x1='8' y1='21' x2='16' y2='21'/><line x1='12' y1='17' x2='12' y2='21'/>")}}
          {{Peer(196, 210, "<rect x='3' y='5' width='18' height='12' rx='2'/><line x1='1' y1='20' x2='23' y2='20'/>")}}
          {{Peer(448, 210, "<rect x='6' y='2' width='12' height='20' rx='2.5'/><line x1='10' y1='18.5' x2='14' y2='18.5'/>")}}
        """;
        return (css, body);
    }

    // ---- Page 8: Import & Export (.tlpack) ----------------------------------------------------

    static (string css, string body) Page8ImportExport(bool dark, string card, string line, string fg2)
    {
        const string accent = "#f43f5e";
        var css = """
          .arr1 { animation: arrPulse 3.6s ease-in-out infinite; }
          .arr2 { animation: arrPulse 3.6s ease-in-out 1.2s infinite; }
          .chk  { animation: chkPop 3.6s ease-in-out infinite; transform-origin: 492px 170px; }
          @keyframes arrPulse { 0%,40%,100% { opacity:0.35; transform:translateX(0); } 20% { opacity:1; transform:translateX(4px); } }
          @keyframes chkPop { 0%,55% { opacity:0; transform:scale(0.5); } 68%,94% { opacity:1; transform:scale(1); } 100% { opacity:0; } }
        """;

        var body = $$"""
          <!-- Left: Folder + JSON sources -->
          <rect x="132" y="76" width="58" height="58" rx="15" fill="#0078d4" fill-opacity="0.16" stroke="#0078d4" stroke-opacity="0.6" stroke-width="1.4"/>
          <path d="M148 99a3 3 0 0 1 3-3h6l3 3h11a3 3 0 0 1 3 3v12a3 3 0 0 1-3 3h-20a3 3 0 0 1-3-3z" fill="none" stroke="#0078d4" stroke-width="1.8"/>

          <rect x="132" y="156" width="58" height="58" rx="15" fill="#f97316" fill-opacity="0.16" stroke="#f97316" stroke-opacity="0.6" stroke-width="1.4"/>
          <text x="161" y="189" text-anchor="middle" font-size="13" font-weight="700" fill="#f97316">{ }</text>

          <!-- Arrow 1 -->
          <path class="arr1" d="M214 147h22M229 140l7 7-7 7" fill="none" stroke="{{accent}}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>

          <!-- Center: TwimShelf Library -->
          <rect x="266" y="96" width="102" height="102" rx="24" fill="{{card}}" stroke="{{accent}}" stroke-width="1.6"/>
          <g transform="translate(297,127)" fill="none" stroke="{{accent}}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
            <rect x="4" y="4" width="14" height="14" rx="3"/><rect x="22" y="4" width="14" height="14" rx="3"/>
            <rect x="4" y="22" width="14" height="14" rx="3"/><rect x="22" y="22" width="14" height="14" rx="3"/>
          </g>

          <!-- Arrow 2 -->
          <path class="arr2" d="M392 147h22M407 140l7 7-7 7" fill="none" stroke="{{accent}}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>

          <!-- Right: .tlpack -->
          <rect x="444" y="96" width="82" height="82" rx="20" fill="{{accent}}" fill-opacity="0.16" stroke="{{accent}}" stroke-width="1.6"/>
          <g transform="translate(469,121)" fill="none" stroke="{{accent}}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M16 3l13 7.5v15L16 33 3 25.5v-15z"/><path d="M3 10.5L16 18l13-7.5M16 18v15"/>
          </g>
          <g class="chk">
            <circle cx="520" cy="172" r="11" fill="#10b981"/>
            <path d="M515 172l3.5 3.5 6.5-6.5" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"/>
          </g>
          <rect x="451" y="192" width="68" height="22" rx="11" fill="{{accent}}" fill-opacity="0.16"/>
          <text x="485" y="206.5" text-anchor="middle" font-size="11" font-weight="700" font-family="Cascadia Mono, Consolas, monospace" fill="{{accent}}">.tlpack</text>
        """;
        return (css, body);
    }
}
