import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_dropdown_tile.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/pages/video/episode_layout.dart';
import 'package:kazumi/services/layout/classic_layout.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 新版 or 经典, each drawn as a small 追番 screen. Shared by onboarding and
/// 外观设置.
class LayoutStylePicker extends StatelessWidget {
  const LayoutStylePicker({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: ClassicLayout.listenable,
    builder: (context, classic, _) => LayoutBuilder(
      builder: (context, constraints) {
        final cards = [
          for (final option in [false, true])
            _StyleCard(
              classic: option,
              selected: option == classic,
              onTap: () {
                if (option != classic) unawaited(ClassicLayout.set(option));
              },
            ),
        ];
        if (constraints.maxWidth < 280) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [cards[0], const SizedBox(height: 12), cards[1]],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: cards[0]),
              const SizedBox(width: 12),
              Expanded(child: cards[1]),
            ],
          ),
        );
      },
    ),
  );
}

class _StyleCard extends StatelessWidget {
  const _StyleCard({
    required this.classic,
    required this.selected,
    required this.onTap,
  });

  final bool classic;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300);
    const curve = Curves.easeInOutCubicEmphasized;
    final title = classic ? '经典' : '新版';
    final radius = BorderRadius.circular(selected ? 28 : 20);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      // Screen readers can't see the preview, so they get it in words.
      label: '$title布局，${classic ? '海报墙，一屏看得更多' : '列表排版，留白多'}',
      onTap: onTap,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: duration,
        curve: curve,
        decoration: BoxDecoration(
          color: selected
              ? colors.secondaryContainer
              : colors.surfaceContainerHigh,
          borderRadius: radius,
          border: Border.all(
            color: selected ? colors.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedScale(
                    scale: selected ? 1 : 0.95,
                    duration: duration,
                    curve: curve,
                    child: _StylePreview(classic: classic, active: selected),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? colors.onSecondaryContainer
                                : colors.onSurface,
                          ),
                        ),
                      ),
                      AnimatedSwitcher(
                        duration: duration,
                        transitionBuilder: (child, animation) =>
                            ScaleTransition(scale: animation, child: child),
                        child: Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          key: ValueKey(selected),
                          size: 22,
                          color: selected ? colors.primary : colors.outline,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A sketch of 追番: a list of rows for 新版, a poster grid for 经典.
class _StylePreview extends StatelessWidget {
  const _StylePreview({required this.classic, required this.active});

  final bool classic;
  final bool active;

  static const _height = 124.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300);
    final ink = colors.onSurfaceVariant.withValues(alpha: 0.35);
    final covers = active
        ? [colors.primaryContainer, colors.tertiaryContainer]
        : [colors.surfaceContainerHighest, colors.surfaceContainerHigh];

    Widget block(double width, double height, Color color, [double r = 3]) =>
        AnimatedContainer(
          duration: duration,
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(r),
          ),
        );

    return ExcludeSemantics(
      child: Container(
        height: _height,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      block(width * 0.3, 6, ink, 3),
                      const Spacer(),
                      block(6, 6, ink, 3),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      for (var i = 0; i < 3; i++) ...[
                        block(
                          18,
                          4,
                          i == 0 ? colors.primary.withValues(alpha: 0.6) : ink,
                          2,
                        ),
                        const SizedBox(width: 6),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (classic)
                    _grid(width, covers, ink, block)
                  else
                    _rows(covers, ink, block),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _grid(
    double width,
    List<Color> covers,
    Color ink,
    Widget Function(double, double, Color, [double]) block,
  ) {
    // Drawn at list-row scale rather than as the phone's three columns, so
    // the sketch shows what 经典 is for: more shows per screen.
    const gap = 4.0;
    final columns = ((width + gap) / (26 + gap)).floor().clamp(4, 6);
    final cell = (width - gap * (columns - 1)) / columns;
    return Wrap(
      spacing: gap,
      runSpacing: 6,
      children: [
        for (var i = 0; i < columns * 2; i++)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              block(cell, cell / 0.65, covers[i % 2]),
              const SizedBox(height: 3),
              block(cell * 0.8, 3, ink, 2),
            ],
          ),
      ],
    );
  }

  Widget _rows(
    List<Color> covers,
    Color ink,
    Widget Function(double, double, Color, [double]) block,
  ) => Column(
    children: [
      for (var i = 0; i < 4; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              block(15, 22, covers[i % 2]),
              const SizedBox(width: 6),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      block(constraints.maxWidth * (0.9 - i * 0.1), 4, ink, 2),
                      const SizedBox(height: 4),
                      block(
                        math.min(40, constraints.maxWidth * 0.5),
                        3,
                        ink,
                        2,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// 外观设置 → 布局: the style, then each screen's own default.
class LayoutSettingsSection extends StatefulWidget {
  const LayoutSettingsSection({super.key});

  @override
  State<LayoutSettingsSection> createState() => _LayoutSettingsSectionState();
}

class _LayoutSettingsSectionState extends State<LayoutSettingsSection> {
  late CollectLayout _collect = _savedCollect();
  late EpisodeLayout _episode = EpisodeLayout.saved;

  static CollectLayout _savedCollect() => CollectLayout.fromValue(
    GStorage.getSetting(SettingsKeys.defaultCollectLayout),
  );

  @override
  void initState() {
    super.initState();
    ClassicLayout.listenable.addListener(_reload);
  }

  @override
  void dispose() {
    ClassicLayout.listenable.removeListener(_reload);
    super.dispose();
  }

  // Switching the style rewrites both defaults.
  void _reload() => setState(() {
    _collect = _savedCollect();
    _episode = EpisodeLayout.saved;
  });

  Future<void> _setCollect(CollectLayout layout) async {
    if (layout == _collect) return;
    setState(() => _collect = layout);
    try {
      await GStorage.putSetting(SettingsKeys.defaultCollectLayout, layout.name);
    } catch (_) {
      if (!mounted) return;
      setState(() => _collect = _savedCollect());
      KazumiDialog.showToast(message: '追番默认布局保存失败，请重试');
    }
  }

  void _setEpisode(EpisodeLayout layout) {
    if (layout == _episode) return;
    setState(() => _episode = layout);
    unawaited(EpisodeLayout.save(layout));
  }

  @override
  Widget build(BuildContext context) => SettingsSection(
    title: const Text('布局'),
    tiles: [
      const Padding(padding: EdgeInsets.all(12), child: LayoutStylePicker()),
      SettingsDropdownTile<CollectLayout>(
        leading: Icons.view_agenda_rounded,
        title: const Text('追番默认布局'),
        description: const Text('下次打开追番页时使用，页面内切换不会改变此设置'),
        value: _collect,
        options: {
          for (final layout in CollectLayout.values) layout: layout.label,
        },
        onChanged: _setCollect,
      ),
      SettingsDropdownTile<EpisodeLayout>(
        leading: Icons.video_library_rounded,
        title: const Text('选集布局'),
        description: const Text('在播放页的选集列表里也能换'),
        value: _episode,
        options: {
          for (final layout in EpisodeLayout.values) layout: layout.label,
        },
        icons: {for (final layout in EpisodeLayout.values) layout: layout.icon},
        onChanged: _setEpisode,
      ),
    ],
    bottomInfo: const Text('换成新版或经典时，追番和选集会跟着换，之后也能单独改。'),
  );
}
