import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'core/core_client.dart';

import 'screens/collections_screen.dart';
import 'screens/search_screen.dart';
import 'screens/transfers_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Opens the profile store on the core isolate; on first run this creates
  // the device's first profile (docs/architecture.md, 3.2).
  await Core.instance.start();
  runApp(const ArcaApp());
}

class ArcaApp extends StatelessWidget {
  const ArcaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arca',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: arcaDarkTheme(),
      theme: arcaDarkTheme(),
      home: const HomeShell(),
    );
  }
}

/// Neutral near-black surfaces, like a video site at night, with white
/// buttons and accents. Colour is left to thumbnails and the app icon.
ThemeData arcaDarkTheme() {
  const background = Color(0xFF0F0F0F);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: Colors.grey,
        brightness: Brightness.dark,
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      ).copyWith(
        primary: Colors.white,
        onPrimary: background,
        primaryContainer: const Color(0xFF3A3A3A),
        onPrimaryContainer: Colors.white,
        secondary: const Color(0xFFDDDDDD),
        onSecondary: background,
        secondaryContainer: const Color(0xFF2A2A2A),
        onSecondaryContainer: const Color(0xFFE6E6E6),
        tertiaryContainer: const Color(0xFF242424),
        surface: background,
        onSurface: const Color(0xFFF1F1F1),
        onSurfaceVariant: const Color(0xFFAAAAAA),
        surfaceContainerLowest: const Color(0xFF0A0A0A),
        surfaceContainerLow: const Color(0xFF161616),
        surfaceContainer: const Color(0xFF1C1C1C),
        surfaceContainerHigh: const Color(0xFF232323),
        surfaceContainerHighest: const Color(0xFF2C2C2C),
        outline: const Color(0xFF4A4A4A),
        outlineVariant: const Color(0xFF303030),
        surfaceTint: Colors.transparent,
      );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    canvasColor: background,
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: background,
      indicatorColor: Color(0xFF2C2C2C),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: background,
      indicatorColor: Color(0xFF2C2C2C),
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: const CardThemeData(
      color: Color(0xFF1C1C1C),
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFF1C1C1C),
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: const DividerThemeData(color: Color(0xFF272727)),
    searchBarTheme: const SearchBarThemeData(
      backgroundColor: WidgetStatePropertyAll(Color(0xFF1E1E1E)),
      surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
    ),
  );
}

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// The home page (search and recommendations) is reached through the Arca
/// logo, so it has no destination of its own on wide screens.
const _destinations = [
  _Destination('Collections', Icons.folder_copy_outlined, Icons.folder_copy),
  _Destination(
    'Transfers',
    Icons.swap_vert_circle_outlined,
    Icons.swap_vert_circle,
  ),
];

/// Bottom navigation on phones, a side rail on wide screens.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// 0 is home; 1 and 2 are the destinations below the logo.
  int _index = 0;

  void _goHome() {
    setState(() => _index = 0);
    SearchScreen.goHome();
  }

  static const _pages = [
    SearchScreen(),
    CollectionsScreen(),
    TransfersScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final body = IndexedStack(index: _index, children: _pages);

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index == 0 ? null : _index - 1,
              onDestinationSelected: (i) => setState(() => _index = i + 1),
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: _ArcaMark(selected: _index == 0, onTap: _goHome),
              ),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) =>
            i == 0 ? _goHome() : setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset('assets/icon/arca.png', width: 24, height: 24),
            ),
            label: 'Arca',
          ),
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

/// The Arca logo; tapping it returns to the home page.
class _ArcaMark extends StatelessWidget {
  const _ArcaMark({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Home',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: selected ? scheme.onSurface : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/icon/arca.png',
                    width: 40,
                    height: 40,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text('Arca', style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
        ),
      ),
    );
  }
}
