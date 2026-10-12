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
}
