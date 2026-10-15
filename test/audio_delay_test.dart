import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/audio_delay.dart';

void main() {
  test('labels', () {
    expect(formatAudioDelay(0), '无偏移');
    expect(formatAudioDelay(-200), '声音提前 200 毫秒');
    expect(formatAudioDelay(150), '声音延后 150 毫秒');
  });

  test('menu label shows the value only when set', () {
    expect(audioDelayMenuLabel(0), '音频同步');
    expect(audioDelayMenuLabel(-200), '音频同步（提前 200 毫秒）');
    expect(audioDelayMenuLabel(30), '音频同步（延后 30 毫秒）');
  });

  test('rounds to 10 ms and clamps to ±1 s', () {
    expect(normalizeAudioDelay(-224), -220);
    expect(normalizeAudioDelay(226), 230);
    expect(normalizeAudioDelay(5000), 1000);
    expect(normalizeAudioDelay(-5000), -1000);
  });

  test('mpv gets seconds; earlier audio is negative', () {
    expect(audioDelayMpvValue(-200), '-0.200');
    expect(audioDelayMpvValue(0), '0.000');
    expect(audioDelayMpvValue(1000), '1.000');
  });
}
