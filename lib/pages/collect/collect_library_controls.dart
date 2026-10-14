part of 'collect_library_view.dart';

class _CollectCategories extends StatelessWidget {
  const _CollectCategories({
    super.key,
    required this.controller,
    required this.count,
  });

  final TabController controller;
  final int Function(CollectType?) count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return TabBar(
      key: const PageStorageKey('collect-filter-strip'),
      controller: controller,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      dividerHeight: 0,
      indicatorSize: TabBarIndicatorSize.tab,
      indicatorPadding: const EdgeInsets.symmetric(horizontal: 2),
      indicator: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      indicatorAnimation: TabIndicatorAnimation.elastic,
      labelColor: colors.onPrimaryContainer,
      unselectedLabelColor: colors.onSurfaceVariant,
      labelStyle:
          theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      unselectedLabelStyle:
          theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500),
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      splashBorderRadius: BorderRadius.circular(24),
      tabs: [
        for (final type in _collectCategories)
          Tab(
            height: 48,
            child: Semantics(
              label: '${type?.label ?? '全部'}，${count(type)} 部',
              excludeSemantics: true,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 64),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    type?.label ?? '全部',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Sort and layout share one menu in the title bar.
class _CollectViewMenu extends StatelessWidget {
  const _CollectViewMenu({
    required this.sort,
    required this.layout,
    required this.onSort,
    required this.onLayout,
  });

  final CollectSort sort;
  final CollectLayout layout;
  final ValueChanged<CollectSort> onSort;
  final ValueChanged<CollectLayout> onLayout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            text,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
    return KazumiMenuButton(
      menuChildren: [
        heading('排序'),
        for (final value in CollectSort.values)
          KazumiMenuItem(
            selected: sort == value,
            onPressed: () => onSort(value),
            label: value.label,
          ),
        const Divider(),
        heading('布局'),
        for (final value in [CollectLayout.cards, CollectLayout.list])
          KazumiMenuItem(
            selected: layout == value,
            leadingIcon: Icon(value == CollectLayout.list
                ? Icons.view_list_rounded
                : Icons.grid_view_rounded),
            onPressed: () => onLayout(value),
            label: '${value.label}布局',
          ),
      ],
      builder: (context, toggle) => IconButton(
        tooltip: '排序与布局',
        onPressed: toggle,
        icon: const Icon(Icons.tune_rounded),
      ),
    );
  }
}
