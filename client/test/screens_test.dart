import 'package:cutsheet_client/src/models.dart';
import 'package:cutsheet_client/src/screens/project_screen.dart';
import 'package:cutsheet_client/src/screens/projects_screen.dart';
import 'package:cutsheet_client/src/screens/sheet_view.dart';
import 'package:cutsheet_client/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_backend.dart';

Widget app(Widget home) => MaterialApp(
      theme: cutsheetTheme(),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: home,
    );

void desktop(WidgetTester t) {
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
}

Future<void> settle(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await t.pump();
}

void main() {
  setUpAll(loadDesignFonts);


  testWidgets('список проектов: статусы и фильтр «Готовы»', (t) async {
    desktop(t);
    final api = (await t.runAsync(FakeBackend().api))!;
    await t.pumpWidget(app(ProjectsScreen(api: api)));
    await settle(t);
    expect(find.text('Готов к проверке'), findsOneWidget);
    expect(find.text('Обработка · диалоги'), findsOneWidget);
    expect(find.text('Ошибка: диалоги'), findsOneWidget);

    await t.tap(find.text('Готовы'));
    await t.pump();
    expect(find.text('Сосед'), findsOneWidget); // остаётся в «Недавних»
    expect(find.text('Тестовый ролик'), findsOneWidget);
    expect(find.text('Обработка · диалоги'), findsNothing);
  });

  testWidgets('готовый проект открывается листом; фильтр «Проверить» оставляет сомнительные строки', (t) async {
    desktop(t);
    final b = FakeBackend();
    final api = (await t.runAsync(b.api))!;
    await t.pumpWidget(app(ProjectScreen(api: api, project: Project.fromJson(b.projects.first))));
    await settle(t);
    expect(find.byType(SheetTable), findsOneWidget);
    expect(find.text('Все · 8'), findsOneWidget);
    expect(find.byType(EditedMark), findsOneWidget);

    await t.tap(find.text('Проверить · 2'));
    await t.pump();
    expect(find.byType(SceneRowView), findsNWidgets(2));
    expect(find.text('? НЕ РАСПОЗНАНО'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30)); // таймауты подключения к хабу
  });

  testWidgets('проект в обработке показывает этапы и найденные сцены', (t) async {
    desktop(t);
    final b = FakeBackend(stage: 'dialogue', status: 'running');
    final api = (await t.runAsync(b.api))!;
    await t.pumpWidget(app(ProjectScreen(api: api, project: Project.fromJson(b.projects.first))));
    await settle(t);
    expect(find.text('Диалоги сопоставляются'), findsOneWidget);
    expect(find.text('Сцены найдены'), findsOneWidget);
    expect(find.text('8 сцен по склейкам'), findsOneWidget);

    await t.tap(find.text('Открыть лист'));
    await t.pump();
    expect(find.byType(SheetTable), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 30)); // таймауты подключения к хабу
  });
}
