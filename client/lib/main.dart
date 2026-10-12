import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';

import 'src/api.dart';
import 'src/screens/login_screen.dart';
import 'src/screens/projects_screen.dart';
import 'src/ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // встроенный плеер (libmpv)
  runApp(CutsheetApp(api: Api()));
}

class CutsheetApp extends StatefulWidget {
  const CutsheetApp({super.key, required this.api});
  final Api api;

  @override
  State<CutsheetApp> createState() => _CutsheetAppState();
}

class _CutsheetAppState extends State<CutsheetApp> {
  late final Future<bool> _restored = widget.api.restore().catchError((_) => false);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CutSheet',
      theme: cutsheetTheme(),
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: FutureBuilder<bool>(
        future: _restored,
        builder: (context, snap) {
          if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          return ListenableBuilder(
            listenable: widget.api,
            builder: (_, _) => widget.api.signedIn ? ProjectsScreen(api: widget.api) : LoginScreen(api: widget.api),
          );
        },
      ),
    );
  }
}
