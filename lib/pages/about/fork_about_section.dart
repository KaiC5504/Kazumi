import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/content_section.dart';
import 'package:kazumi/build_flavor.dart';
import 'package:kazumi/pages/about/about_widgets.dart';
import 'package:kazumi/request/config/api_endpoints.dart';

const forkRepoUrl = 'https://github.com/KaiC5504/Kazumi';

/// Shown on the About page of public builds only.
class ForkAboutSection extends StatelessWidget {
  const ForkAboutSection({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: ContentSection.group(
      title: '$kForkName ${ApiEndpoints.version}',
      description: '基于 Predidit/Kazumi · 与官方无关',
      children: const [
        AboutLinkTile(
          icon: Icons.code_rounded,
          title: '$kForkName 源代码',
          url: forkRepoUrl,
        ),
        AboutLinkTile(
          icon: Icons.new_releases_outlined,
          title: '$kForkName 下载与更新日志',
          url: '$forkRepoUrl/releases',
        ),
        AboutLinkTile(
          icon: Icons.bug_report_outlined,
          title: '$kForkName 问题反馈',
          url: '$forkRepoUrl/issues',
        ),
      ],
    ),
  );
}
