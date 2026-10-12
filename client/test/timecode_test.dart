import 'package:cutsheet_client/src/timecode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('кадры считаются по fps', () {
    expect(timecode(0, 25), '00:00:00:00');
    expect(timecode(2000, 25), '00:00:02:00');
    expect(timecode(2520, 25), '00:00:02:13');
    expect(timecode(3661040, 25), '01:01:01:01');
    expect(timecode(1999, 24), '00:00:01:23');
  });

  test('без fps — 25 кадр/с', () => expect(timecode(1040, null), '00:00:01:01'));

  test('длительность', () => expect(seconds(2500), '2,5 с'));

  test('таймкод разбирается обратно в тот же кадр', () {
    for (final fps in [25.0, 23.976, 29.97, 24.0]) {
      for (var ms = 0; ms < 5000; ms += 7) {
        final tc = timecode(ms, fps);
        expect(timecode(parseTimecode(tc, fps)!, fps), tc, reason: '$ms мс при $fps');
      }
    }
    expect(parseTimecode('01:02:03:04', 25), 3723160);
    expect(parseTimecode('03:04', 25), 3160);
    expect(parseTimecode('00:61:00:00', 25), isNull);
    expect(parseTimecode('00:00:00:25', 25), isNull);
    expect(parseTimecode('abc', 25), isNull);
  });
}
