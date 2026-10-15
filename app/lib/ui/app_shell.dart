import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import 'generate/generate_page.dart';
import 'scan/scan_page.dart';
import 'settings/settings_page.dart';

/// The three-tab shell: 扫描 / 生成 / 设置.
///
/// All three pages stay alive in an [IndexedStack] so switching tabs preserves
/// each page's state (project spec §5). The scan page is told whether it is the
/// visible tab and whether the app is in the foreground, and starts or releases
/// the camera accordingly — that single signal is what stops the camera running
/// in the background or while another tab is on screen (§4.6).
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  bool _isForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final scope = AppScope.of(context);

    switch (state) {
      case AppLifecycleState.resumed:
        if (!_isForeground) {
          setState(() => _isForeground = true);
        }
        // The user may be returning from the system installer; this is where an
        // interrupted install is detected (project spec §3.1).
        unawaited(scope.update.onResume());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(scope.scan.stopScanning());
        if (_isForeground) {
          setState(() => _isForeground = false);
        }
      case AppLifecycleState.inactive:
        // Transient (a system dialog, the app switcher). Releasing the camera
        // here would make the permission prompt interrupt its own scan, so this
        // state deliberately does nothing.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          ScanPage(isActive: _selectedIndex == 0 && _isForeground),
          const GeneratePage(),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          if (index == _selectedIndex) {
            return;
          }
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner_outlined),
            selectedIcon: Icon(Icons.qr_code_scanner),
            label: '扫描',
          ),
          NavigationDestination(
            icon: Icon(Icons.qr_code_2_outlined),
            selectedIcon: Icon(Icons.qr_code_2),
            label: '生成',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
