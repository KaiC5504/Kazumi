import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/pages/collect/collect_library_query.dart';

part 'collect_library_card.dart';
part 'collect_library_controls.dart';

const _collectCategories = <CollectType?>[
  null,
  CollectType.watching,
  CollectType.planToWatch,
  CollectType.watched,
  CollectType.onHold,
  CollectType.abandoned,
];

class CollectLibraryView extends StatefulWidget {
  const CollectLibraryView({
    super.key,
    required this.title,
    this.actions = const [],
    required this.entries,
    required this.showRating,
    this.watchProgress = const {},
    required this.onOpen,
    required this.onChangeType,
    required this.canEdit,
    required this.layout,
    required this.onLayoutChanged,
    this.classic = false,
  });

  final String title;
  final List<Widget> actions;
  final List<CollectedBangumi> entries;
  final bool showRating;
  final Map<int, String> watchProgress;
  final ValueChanged<BangumiItem> onOpen;
  final void Function(BangumiItem, CollectType) onChangeType;
  final bool Function(BangumiItem) canEdit;
  final CollectLayout layout;
  final ValueChanged<CollectLayout> onLayoutChanged;

  /// 经典布局: the old dense poster grid for the card layout.
  final bool classic;

  @override
  State<CollectLibraryView> createState() => _CollectLibraryViewState();
}

class _CollectLibraryViewState extends State<CollectLibraryView>
    with TickerProviderStateMixin {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _libraryFocus = FocusNode();
  // Keep tab animations alive when the category scroll view is replaced.
  final _categoriesKey = GlobalKey();
  late TabController _tabController;
  bool? _disableAnimations;
  final _scrollControllers = {
    for (final type in _collectCategories) type: ScrollController(),
  };
  PageStorageBucket _resultsStorage = PageStorageBucket();
  CollectType? _selectedType = CollectType.watching;
  CollectSort _sort = CollectSort.recentlyChanged;
  String _query = '';
  bool _searchExpanded = false;
  // Phone header below the status bar, measured; the guess covers frame one.
  double _compactHeaderHeight = _titleBarHeight + 56;

  static const _titleBarHeight = 72.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations == disableAnimations) return;
    if (_disableAnimations != null) {
      _tabController.dispose();
    }
    _disableAnimations = disableAnimations;
    _tabController = TabController(
      length: _collectCategories.length,
      initialIndex: _collectCategories.indexOf(_selectedType),
      animationDuration: disableAnimations ? Duration.zero : null,
      vsync: this,
    )..addListener(_onCategoryChanged);
  }

  @override
  void didUpdateWidget(covariant CollectLibraryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout != widget.layout ||
        oldWidget.classic != widget.classic) {
      _resetResults();
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _libraryFocus.dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _resetResults() {
    // Reset saved offsets for unmounted categories too.
    _resultsStorage = PageStorageBucket();
    for (final controller in _scrollControllers.values) {
      if (controller.hasClients) controller.jumpTo(0);
    }
  }

  void _focusSearch() {
    final controller = _scrollControllers[_selectedType]!;
    if (controller.hasClients) controller.jumpTo(0);
    setState(() => _searchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _libraryFocus.requestFocus();
    _searchController.clear();
    setState(() {
      _searchExpanded = false;
      _query = '';
      _resetResults();
    });
  }

  void _search(String value) {
    setState(() {
      _query = value;
      _resetResults();
    });
  }

  void _onCategoryChanged() {
    final type = _collectCategories[_tabController.index];
    if (type == _selectedType) return;
    _libraryFocus.requestFocus();
    setState(() => _selectedType = type);
  }

  @override
  Widget build(BuildContext context) {
    final query = CollectLibraryQuery(widget.entries, _query);
    final platform = Theme.of(context).platform;
    final mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
      },
      child: Focus(
        focusNode: _libraryFocus,
        autofocus: true,
        child: LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxWidth < 600;
          final paged = mobile &&
              MediaQuery.orientationOf(context) == Orientation.portrait &&
              constraints.maxHeight > 320;
          final width = constraints.maxWidth.clamp(0.0, 1560.0);
          final inset =
              (constraints.maxWidth - width) / 2 + (compact ? 16.0 : 32.0);
          if (compact) {
            return PageStorage(
              bucket: _resultsStorage,
              child: _compactLibrary(query, inset: inset, paged: paged),
            );
          }
          final header = _header(query);
          final library = paged
              ? Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: inset),
                      child: header,
                    ),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          for (final type in _collectCategories)
                            HeroMode(
                              enabled: type == _selectedType,
                              child: _results(query, type, inset: inset),
                            ),
                        ],
                      ),
                    ),
                  ],
                )
              : _results(query, _selectedType, inset: inset, header: header);
          return PageStorage(
            bucket: _resultsStorage,
            child: Column(
              children: [
                _titleBar(query, compact: false),
                Expanded(child: library),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _header(CollectLibraryQuery query) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _categories(query)),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 16),
              child: Text(
                '${query.count(_selectedType)} 部',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: _searchBar(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            _CollectSortMenu(
              value: _sort,
              showLabel: true,
              onChanged: _changeSort,
            ),
            const SizedBox(width: 8),
            _CollectLayoutSwitch(
              value: widget.layout,
              onChanged: widget.onLayoutChanged,
            ),
          ],
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _categories(CollectLibraryQuery query) => _CollectCategories(
        key: _categoriesKey,
        controller: _tabController,
        count: query.count,
      );

  void _changeSort(CollectSort sort) => setState(() {
        _sort = sort;
        _resetResults();
      });

  Widget _titleBar(CollectLibraryQuery query, {required bool compact}) {
    final theme = Theme.of(context);
    final title = Text(
      widget.title,
      style:
          theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
    );
    return SysAppBar(
      needTopOffset: false,
      toolbarHeight: _titleBarHeight,
      // On phones the count moves up here from the controls row it replaces.
      // Filling the title slot keeps it at the start: iOS centres app bar
      // titles, which left a gap beside three actions.
      title: compact
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                title,
                const SizedBox(width: 8),
                Text(
                  '${query.count(_selectedType)} 部',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            )
          : title,
      actions: [
        if (compact) ...[
          IconButton(
            tooltip: _searchExpanded ? '收起搜索' : '搜索收藏',
            isSelected: _searchExpanded,
            selectedIcon: const Icon(Icons.search_off_rounded),
            icon: const Icon(Icons.search_rounded),
            onPressed: _searchExpanded ? _closeSearch : _focusSearch,
          ),
          _CollectViewMenu(
            sort: _sort,
            layout: widget.layout,
            onSort: _changeSort,
            onLayout: widget.onLayoutChanged,
          ),
          const SizedBox(width: 4),
        ],
        ...widget.actions,
      ],
    );
  }

  /// Phones: the title bar scrolls away with the list while the category tabs
  /// stay pinned under the status bar. It comes back only at the top of the
  /// list, never on a small scroll up.
  Widget _compactLibrary(CollectLibraryQuery query,
      {required double inset, required bool paged}) {
    final colors = Theme.of(context).colorScheme;
    final statusBar = MediaQuery.paddingOf(context).top;
    final top = statusBar + _compactHeaderHeight;
    final header = ColoredBox(
      color: colors.surface,
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _titleBar(query, compact: true),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              child: _categories(query),
            ),
            if (_searchExpanded)
              Padding(
                padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
                child: _searchBar(),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: paged
              ? TabBarView(
                  controller: _tabController,
                  children: [
                    for (final type in _collectCategories)
                      HeroMode(
                        enabled: type == _selectedType,
                        child: _results(query, type, inset: inset, top: top),
                      ),
                  ],
                )
              : _results(query, _selectedType, inset: inset, top: top),
        ),
        Positioned(
          top: statusBar,
          left: 0,
          right: 0,
          child: ClipRect(
            child: ListenableBuilder(
              listenable: _scrollControllers[_selectedType]!,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, -_titleBarCollapse()),
                child: child,
              ),
              child: _HeightReporter(
                onHeight: (height) {
                  if (mounted && height != _compactHeaderHeight) {
                    setState(() => _compactHeaderHeight = height);
                  }
                },
                child: header,
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: statusBar,
          child: ColoredBox(color: colors.surface),
        ),
      ],
    );
  }

  double _titleBarCollapse() {
    final positions = _scrollControllers[_selectedType]!.positions;
    if (positions.isEmpty || !positions.first.hasPixels) return 0;
    return positions.first.pixels.clamp(0.0, _titleBarHeight);
  }

  Widget _searchBar() => Semantics(
        label: '搜索收藏',
        child: SearchBar(
          controller: _searchController,
          focusNode: _searchFocus,
          leading: const Icon(Icons.search_rounded, size: 22),
          trailing: [
            if (_query.isNotEmpty)
              IconButton(
                tooltip: '清除搜索',
                onPressed: () {
                  _searchController.clear();
                  _search('');
                },
                icon: const Icon(Icons.close_rounded),
              ),
          ],
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStatePropertyAll(
              Theme.of(context).colorScheme.surfaceContainerLow),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 16)),
          constraints: const BoxConstraints(minHeight: 48),
          onChanged: _search,
          onSubmitted: (_) => _libraryFocus.requestFocus(),
        ),
      );

  Widget _results(CollectLibraryQuery query, CollectType? type,
      {required double inset, Widget? header, double top = 0}) {
    return LayoutBuilder(builder: (context, constraints) {
      final entries = query.results(type, _sort);
      final contentWidth = constraints.maxWidth - inset * 2;
      return ScrollbarTheme(
        data: ScrollbarTheme.of(context).copyWith(crossAxisMargin: 0),
        child: CustomScrollView(
          key: PageStorageKey('collect-results-${type?.value ?? 'all'}'),
          controller: _scrollControllers[type],
          semanticChildCount: entries.length,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            if (top > 0) SliverToBoxAdapter(child: SizedBox(height: top)),
            if (header != null)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: SliverToBoxAdapter(child: header),
              ),
            if (entries.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: inset),
                  child: _emptyState(query.count(null), type: type),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                    inset, 0, inset, 24 + MediaQuery.paddingOf(context).bottom),
                sliver: widget.layout == CollectLayout.cards
                    ? _grid(entries, contentWidth, type: type)
                    : _list(entries, contentWidth),
              ),
          ],
        ),
      );
    });
  }

  Widget _list(List<CollectedBangumi> entries, double contentWidth) {
    const spacing = 12.0;
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, double.infinity);
    final minWidth = 300 + 160 * (textScale - 1);
    final preferredWidth = 400 + 160 * (textScale - 1);
    final maxColumns =
        ((contentWidth + spacing) / (minWidth + spacing)).floor().clamp(1, 12);
    final columns = ((contentWidth + spacing) / (preferredWidth + spacing))
        .ceil()
        .clamp(1, maxColumns);

    Widget tile(int index) => IndexedSemantics(
          index: index,
          child: _CollectListTile(
            key: ValueKey('collect-${entries[index].bangumiItem.id}'),
            entry: entries[index],
            showRating: widget.showRating,
            watchProgress:
                widget.watchProgress[entries[index].bangumiItem.id],
            onOpen: () => widget.onOpen(entries[index].bangumiItem),
            onChangeType: _changeTypeFor(entries[index]),
          ),
        );

    return SliverList.builder(
      itemCount: (entries.length + columns - 1) ~/ columns,
      addSemanticIndexes: false,
      itemBuilder: (context, row) {
        final first = row * columns;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: columns == 1
              ? tile(first)
              : IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: spacing,
                    children: [
                      for (var column = 0; column < columns; column++)
                        Expanded(
                          child: first + column < entries.length
                              ? tile(first + column)
                              : const SizedBox(),
                        ),
                    ],
                  ),
                ),
        );
      },
    );
  }

  ValueChanged<CollectType>? _changeTypeFor(CollectedBangumi entry) =>
      widget.canEdit(entry.bangumiItem)
          ? (type) => widget.onChangeType(entry.bangumiItem, type)
          : null;

  Widget _grid(List<CollectedBangumi> entries, double contentWidth,
      {required CollectType? type}) {
    if (widget.classic) return _classicGrid(entries, contentWidth);
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final spacing = portrait ? (contentWidth < 600 ? 8.0 : 12.0) : 16.0;
    final scaler = MediaQuery.textScalerOf(context);
    final textScale = (scaler.scale(14) / 14).clamp(1.0, double.infinity);
    final minWidth =
        (contentWidth < 600 ? 136.0 : 172.0) + 32 * (textScale - 1);
    // Only phones keep three: a portrait tablet got 370 px wide posters.
    final columns = portrait && contentWidth < 600
        ? 3
        : ((contentWidth + spacing) / (minWidth + spacing)).floor().clamp(1, 6);
    final width = (contentWidth - spacing * (columns - 1)) / columns;
    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: spacing,
        mainAxisSpacing: portrait ? 12 : spacing,
        mainAxisExtent: _CollectPosterCard.extent(width, scaler,
            showRating: widget.showRating, showStatus: type == null),
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) => _CollectPosterCard(
        key: ValueKey('collect-${entries[index].bangumiItem.id}'),
        entry: entries[index],
        showRating: widget.showRating,
        showStatus: type == null,
        watchProgress: widget.watchProgress[entries[index].bangumiItem.id],
        onOpen: () => widget.onOpen(entries[index].bangumiItem),
        onChangeType: _changeTypeFor(entries[index]),
      ),
    );
  }

  /// Columns as before the redesign: three on phones, five, then six.
  Widget _classicGrid(List<CollectedBangumi> entries, double contentWidth) {
    const spacing = 8.0;
    final columns = contentWidth > 840
        ? 6
        : contentWidth > 600
            ? 5
            : 3;
    final width = (contentWidth - spacing * (columns - 1)) / columns;
    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: spacing,
        mainAxisSpacing: spacing,
        mainAxisExtent: _CollectPosterCard.classicExtent(
            width, MediaQuery.textScalerOf(context)),
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) => _CollectPosterCard(
        key: ValueKey('collect-${entries[index].bangumiItem.id}'),
        entry: entries[index],
        showRating: false,
        showStatus: false,
        classic: true,
        watchProgress: widget.watchProgress[entries[index].bangumiItem.id],
        onOpen: () => widget.onOpen(entries[index].bangumiItem),
        onChangeType: _changeTypeFor(entries[index]),
      ),
    );
  }

  Widget _emptyState(int matchCount, {required CollectType? type}) {
    final searching = _query.trim().isNotEmpty;
    final String title;

    if (searching) {
      title = matchCount > 0 ? '当前分类没有匹配的番剧' : '没有找到匹配的番剧';
    } else if (matchCount == 0) {
      title = '还没有收藏的番剧';
    } else {
      title = switch (type) {
        CollectType.watching => '还没有在追的番剧',
        CollectType.planToWatch => '还没有想看的番剧',
        CollectType.watched => '还没有看过的番剧',
        CollectType.onHold => '没有搁置的番剧',
        CollectType.abandoned => '没有弃追的番剧',
        _ => '还没有收藏的番剧',
      };
    }
    return GeneralEmptyState(
      icon: searching ? Icons.search_off_rounded : Icons.video_library_outlined,
      title: title,
    );
  }
}

class _HeightReporter extends SingleChildRenderObjectWidget {
  const _HeightReporter({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeightReporter(onHeight);

  @override
  void updateRenderObject(
          BuildContext context, _RenderHeightReporter renderObject) =>
      renderObject.onHeight = onHeight;
}

class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    // Layout can't set state, so the list padding follows a frame later.
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}
