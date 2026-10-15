import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';
import 'package:kazumi/services/player/audio_delay.dart';
import 'package:kazumi/services/storage/storage.dart';

class AudioDelaySheet extends StatefulWidget {
  const AudioDelaySheet({super.key, required this.onChanged});

  final ValueChanged<int> onChanged;

  @override
  State<AudioDelaySheet> createState() => _AudioDelaySheetState();
}

class _AudioDelaySheetState extends State<AudioDelaySheet> {
  late int _delay = normalizeAudioDelay(GStorage.getSetting(audioDelaySetting));

  void _update(num value) {
    final delay = normalizeAudioDelay(value);
    if (delay == _delay) return;
    setState(() => _delay = delay);
    GStorage.putSetting<int>(audioDelaySetting, delay);
    widget.onChanged(delay);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MaterialBottomSheetHeader(
          title: '音频同步',
          description: '声音比画面慢就提前，快就延后。投屏和外部播放器不受影响。',
          onClose: () => Navigator.of(context).pop(),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: materialBottomSheetContentPadding,
            child: Column(
              children: [
                TonalCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton.filledTonal(
                            tooltip: '提前 10 毫秒',
                            onPressed: _delay > audioDelayMinMs
                                ? () => _update(_delay - audioDelayStepMs)
                                : null,
                            icon: const Icon(Icons.remove_rounded),
                          ),
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                formatAudioDelay(_delay),
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          IconButton.filledTonal(
                            tooltip: '延后 10 毫秒',
                            onPressed: _delay < audioDelayMaxMs
                                ? () => _update(_delay + audioDelayStepMs)
                                : null,
                            icon: const Icon(Icons.add_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Slider(
                        value: _delay.toDouble(),
                        min: audioDelayMinMs.toDouble(),
                        max: audioDelayMaxMs.toDouble(),
                        divisions:
                            (audioDelayMaxMs - audioDelayMinMs) ~/
                            audioDelayStepMs,
                        label: formatAudioDelay(_delay),
                        onChanged: _update,
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('提前 1 秒', style: theme.textTheme.labelSmall),
                          Text('延后 1 秒', style: theme.textTheme.labelSmall),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _delay != 0 ? () => _update(0) : null,
                  child: const Text('重置'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
