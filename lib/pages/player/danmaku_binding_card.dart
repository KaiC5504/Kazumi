import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/tonal_card.dart';

class DanmakuBindingCard extends StatelessWidget {
  const DanmakuBindingCard({
    super.key,
    required this.animeTitle,
    required this.onReset,
  });

  final String animeTitle;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return TonalCard(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          const Icon(Icons.link_rounded, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '已绑定：$animeTitle',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          TextButton(onPressed: onReset, child: const Text('恢复自动匹配')),
        ],
      ),
    );
  }
}
