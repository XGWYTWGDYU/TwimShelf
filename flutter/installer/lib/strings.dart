import 'dart:ui';

/// The setup's few texts (it runs before the app and has no catalog of its own).
class S {
  S._(this._t);
  final Map<String, String> _t;

  static S of(Locale l) {
    final tag = l.languageCode == 'zh' ? (l.scriptCode == 'Hant' || ['TW', 'HK', 'MO'].contains(l.countryCode) ? 'zh-Hant' : 'zh-Hans') : l.languageCode;
    return S._(_all[tag] ?? _all['en']!);
  }

  String _f(String k, [List<Object> a = const []]) {
    var s = _t[k]!;
    for (final v in a) {
      s = s.replaceFirst('%s', '$v');
    }
    return s;
  }

  String installTitle(String n) => _f('installTitle', [n]);
  String get installBody => _f('installBody');
  String installing(String n) => _f('installing', [n]);
  String installed(String n) => _f('installed', [n]);
  String get installedBody => _f('installedBody');
  String upgradeTitle(String n) => _f('upgradeTitle', [n]);
  String overwriteTitle(String n) => _f('overwriteTitle', [n]);
  String get keepsData => _f('keepsData');
  String upgradeNotice(String a, String b) => _f('upgradeNotice', [a, b]);
  String reinstallNotice(String v) => _f('reinstallNotice', [v]);
  String downgradeNotice(String a, String b) => _f('downgradeNotice', [a, b]);
  String unknownNotice(String v) => _f('unknownNotice', [v]);
  String closesRunning(String n) => _f('closesRunning', [n]);
  String upgrading(String n) => _f('upgrading', [n]);
  String overwriting(String n) => _f('overwriting', [n]);
  String upgraded(String n, String v) => _f('upgraded', [n, v]);
  String get upgrade => _f('upgrade');
  String get overwrite => _f('overwrite');
  String get installedFolder => _f('installedFolder');
  String get dataKeptNote => _f('dataKeptNote');
  String get dataRemoved => _f('dataRemoved');
  String get dataKept => _f('dataKept');
  String get retry => _f('retry');
  String get finish => _f('finish');
  String uninstallTitle(String n) => _f('uninstallTitle', [n]);
  String get uninstallBody => _f('uninstallBody');
  String uninstalling(String n) => _f('uninstalling', [n]);
  String uninstalled(String n) => _f('uninstalled', [n]);
  String launch(String n) => _f('launch', [n]);
  String get failed => _f('failed');
  String get folder => _f('folder');
  String get change => _f('change');
  String get desktopShortcut => _f('desktopShortcut');
  String get perUser => _f('perUser');
  String get removeData => _f('removeData');
  String get install => _f('install');
  String get uninstall => _f('uninstall');
  String get cancel => _f('cancel');
  String get close => _f('close');

  static const _all = {
    'en': {
      'installTitle': 'Install %s', 'installBody': 'The program goes into one folder; your data stays where you choose on first start.',
      'installing': 'Installing %s…', 'installed': '%s is installed', 'installedBody': 'It is in the Start menu.',
      'uninstallTitle': 'Uninstall %s', 'uninstallBody': 'The program, its shortcuts and its entry in Settings › Apps are removed.',
      'uninstalling': 'Uninstalling %s…', 'uninstalled': '%s is uninstalled',
      'launch': 'Open %s now', 'failed': 'Something went wrong', 'folder': 'Install folder', 'change': 'Change',
      'desktopShortcut': 'Add a shortcut to the desktop', 'perUser': 'Installed for you only; no administrator rights needed.',
      'removeData': 'Also delete my data (library, settings, accounts)', 'install': 'Install', 'uninstall': 'Uninstall', 'cancel': 'Cancel', 'close': 'Close',
      'upgradeTitle': 'Upgrade %s',
      'overwriteTitle': 'Overwrite %s',
      'keepsData': 'Your library and settings are not touched.',
      'upgradeNotice': 'Version %s is installed and will be upgraded to %s.',
      'reinstallNotice': 'Version %s is already installed. Continuing overwrites it with the same version, which can repair damaged program files.',
      'downgradeNotice': 'The installed version %s is newer than this setup\'s %s. Continuing replaces it with the older one, and the older version may not be able to open a library the newer one has written to.',
      'unknownNotice': 'This app is already installed, but its version cannot be read. Continuing overwrites it with version %s.',
      'closesRunning': '%s will be closed if it is running.',
      'upgrading': 'Upgrading %s…',
      'overwriting': 'Overwriting %s…',
      'upgraded': '%s is upgraded to %s',
      'upgrade': 'Upgrade',
      'overwrite': 'Overwrite',
      'installedFolder': 'Installed in',
      'dataKeptNote': 'Your data folder stays unless you tick this.',
      'dataRemoved': 'Your data folder was deleted.',
      'dataKept': 'Your data is still in:',
      'retry': 'Try again',
      'finish': 'Done',
    },
    'zh-Hans': {
      'installTitle': '安装 %s', 'installBody': '程序装在一个文件夹里；数据放在首次启动时你选择的位置。',
      'installing': '正在安装 %s…', 'installed': '%s 已安装', 'installedBody': '可以在开始菜单中找到它。',
      'uninstallTitle': '卸载 %s', 'uninstallBody': '将移除程序、它的快捷方式，以及「设置 › 应用」中的条目。',
      'uninstalling': '正在卸载 %s…', 'uninstalled': '%s 已卸载',
      'launch': '现在打开 %s', 'failed': '出了点问题', 'folder': '安装位置', 'change': '更改',
      'desktopShortcut': '在桌面创建快捷方式', 'perUser': '只为你安装，不需要管理员权限。',
      'removeData': '同时删除我的数据（资料库、设置、账户）', 'install': '安装', 'uninstall': '卸载', 'cancel': '取消', 'close': '关闭',
      'upgradeTitle': '升级 %s',
      'overwriteTitle': '覆盖安装 %s',
      'keepsData': '你的资料库和设置不受影响。',
      'upgradeNotice': '当前已安装版本 %s，将升级到 %s。',
      'reinstallNotice': '这台电脑已安装版本 %s。继续会用相同版本覆盖，可用于修复损坏的程序文件。',
      'downgradeNotice': '已安装的版本 %s 比这个安装程序的 %s 更新。继续会换回旧版本，旧版本可能打不开新版本写入过的资料库。',
      'unknownNotice': '这台电脑已安装此应用，但读不到它的版本。继续会用版本 %s 覆盖。',
      'closesRunning': '如果 %s 正在运行，它会被关闭。',
      'upgrading': '正在升级 %s…',
      'overwriting': '正在覆盖安装 %s…',
      'upgraded': '%s 已升级到 %s',
      'upgrade': '立即升级',
      'overwrite': '覆盖安装',
      'installedFolder': '安装位置',
      'dataKeptNote': '不勾选时，数据文件夹会保留。',
      'dataRemoved': '数据文件夹已删除。',
      'dataKept': '你的数据仍保留在：',
      'retry': '重试',
      'finish': '完成',
    },
    'zh-Hant': {
      'installTitle': '安裝 %s', 'installBody': '程式裝在一個資料夾裡；資料放在首次啟動時你選擇的位置。',
      'installing': '正在安裝 %s…', 'installed': '%s 已安裝', 'installedBody': '可以在開始功能表中找到它。',
      'uninstallTitle': '解除安裝 %s', 'uninstallBody': '將移除程式、它的捷徑，以及「設定 › 應用程式」中的項目。',
      'uninstalling': '正在解除安裝 %s…', 'uninstalled': '%s 已解除安裝',
      'launch': '現在開啟 %s', 'failed': '發生問題', 'folder': '安裝位置', 'change': '變更',
      'desktopShortcut': '在桌面建立捷徑', 'perUser': '只為你安裝，不需要系統管理員權限。',
      'removeData': '同時刪除我的資料（資料庫、設定、帳戶）', 'install': '安裝', 'uninstall': '解除安裝', 'cancel': '取消', 'close': '關閉',
      'upgradeTitle': '升級 %s',
      'overwriteTitle': '覆蓋安裝 %s',
      'keepsData': '你的資料庫和設定不受影響。',
      'upgradeNotice': '目前已安裝版本 %s，將升級到 %s。',
      'reinstallNotice': '這台電腦已安裝版本 %s。繼續會用相同版本覆蓋，可用於修復損壞的程式檔案。',
      'downgradeNotice': '已安裝的版本 %s 比這個安裝程式的 %s 更新。繼續會換回舊版本，舊版本可能打不開新版本寫入過的資料庫。',
      'unknownNotice': '這台電腦已安裝此應用程式，但讀不到它的版本。繼續會用版本 %s 覆蓋。',
      'closesRunning': '如果 %s 正在執行，它會被關閉。',
      'upgrading': '正在升級 %s…',
      'overwriting': '正在覆蓋安裝 %s…',
      'upgraded': '%s 已升級到 %s',
      'upgrade': '立即升級',
      'overwrite': '覆蓋安裝',
      'installedFolder': '安裝位置',
      'dataKeptNote': '不勾選時，資料夾會保留。',
      'dataRemoved': '資料夾已刪除。',
      'dataKept': '你的資料仍保留在：',
      'retry': '重試',
      'finish': '完成',
    },
    'ja': {
      'installTitle': '%s をインストール', 'installBody': 'プログラムは 1 つのフォルダに入り、データは初回起動時に選んだ場所に置かれます。',
      'installing': '%s をインストール中…', 'installed': '%s をインストールしました', 'installedBody': 'スタートメニューにあります。',
      'uninstallTitle': '%s をアンインストール', 'uninstallBody': 'プログラム、ショートカット、「設定 › アプリ」の項目を削除します。',
      'uninstalling': '%s をアンインストール中…', 'uninstalled': '%s をアンインストールしました',
      'launch': '%s を今すぐ開く', 'failed': '問題が発生しました', 'folder': 'インストール先', 'change': '変更',
      'desktopShortcut': 'デスクトップにショートカットを作成', 'perUser': 'このユーザーにだけインストールします。管理者権限は不要です。',
      'removeData': 'データ（ライブラリ、設定、アカウント）も削除', 'install': 'インストール', 'uninstall': 'アンインストール', 'cancel': 'キャンセル', 'close': '閉じる',
      'upgradeTitle': '%s をアップグレード',
      'overwriteTitle': '%s を上書きインストール',
      'keepsData': 'ライブラリと設定はそのまま残ります。',
      'upgradeNotice': 'バージョン %s がインストールされています。%s にアップグレードします。',
      'reinstallNotice': 'バージョン %s はすでにインストールされています。続けると同じバージョンで上書きします。壊れたプログラムファイルの修復に使えます。',
      'downgradeNotice': 'インストール済みのバージョン %s は、このセットアップの %s より新しいものです。続けると古いバージョンに置き換わり、新しいバージョンで書き込んだライブラリを開けなくなる場合があります。',
      'unknownNotice': 'このアプリはすでにインストールされていますが、バージョンを読み取れません。続けるとバージョン %s で上書きします。',
      'closesRunning': '%s が実行中の場合は閉じられます。',
      'upgrading': '%s をアップグレード中…',
      'overwriting': '%s を上書きインストール中…',
      'upgraded': '%s を %s にアップグレードしました',
      'upgrade': 'アップグレード',
      'overwrite': '上書きインストール',
      'installedFolder': 'インストール先',
      'dataKeptNote': 'チェックしない場合、データフォルダは残ります。',
      'dataRemoved': 'データフォルダを削除しました。',
      'dataKept': 'データは次の場所に残っています：',
      'retry': '再試行',
      'finish': '完了',
    },
  };
}
