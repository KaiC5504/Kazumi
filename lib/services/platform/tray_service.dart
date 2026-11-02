import 'dart:io';

import 'package:kazumi/services/logging/logger.dart';
import 'package:tray_manager/tray_manager.dart';

class TrayService {
  TrayService._();

  static bool _iconSet = false;
  static Future<void> _iconUpdate = Future.value();

  static Future<void> initialize() async {
    if (Platform.isWindows) {
      // The icon is added on hide; tooltip and menu are kept for when it is.
    } else if (Platform.environment.containsKey('FLATPAK_ID') ||
        Platform.environment.containsKey('SNAP')) {
      await trayManager.setIcon('io.github.Predidit.Kazumi');
    } else {
      await trayManager.setIcon('assets/images/logo/logo_rounded.png');
    }
    _iconSet = !Platform.isWindows;

    if (!Platform.isLinux) {
      await trayManager.setToolTip('Kazumi');
    }

    Menu trayMenu = Menu(items: [
      MenuItem(key: 'show_window', label: '显示窗口'),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: '退出 Kazumi')
    ]);
    await trayManager.setContextMenu(trayMenu);
  }

  /// Must run before exit(): the plugin only drops the Windows icon on
  /// WM_DESTROY, and its destroy assumes an icon was set.
  static Future<void> dispose() => _queue(() async {
        if (!_iconSet) return;
        _iconSet = false;
        await trayManager.destroy();
      });

  /// On Windows the tray icon only exists while the window is hidden, so the
  /// app sits in either the taskbar or the tray, never both.
  static Future<void> setWindowsIconVisible(bool visible) => _queue(() async {
        if (_iconSet == visible) return;
        _iconSet = visible;
        if (visible) {
          await trayManager.setIcon('assets/images/logo/logo_lanczos.ico');
        } else {
          await trayManager.destroy();
        }
      });

  static Future<void> _queue(Future<void> Function() update) {
    return _iconUpdate = _iconUpdate.then((_) => update()).catchError((e) {
      KazumiLogger().w('Tray: icon update failed', error: e);
    });
  }
}
