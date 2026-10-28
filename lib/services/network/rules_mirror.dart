import 'package:kazumi/build_flavor.dart';
import 'package:kazumi/services/network/acceleration_mode.dart';
import 'package:kazumi/services/storage/storage.dart';

enum RulesMirror implements AccelerationMode {
  // Fork: our HK box, the personal default; public builds don't offer it.
  hk,
  ghProxy,
  ghfast,
  gitcode,
  direct;

  static List<RulesMirror> get choices =>
      kPublicBuild ? values.where((m) => m != hk).toList() : values;

  static RulesMirror get current {
    final stored =
        values.asNameMap()[GStorage.getSetting(SettingsKeys.rulesMirror)];
    if (stored != null && choices.contains(stored)) return stored;
    if (!GStorage.getSetting(SettingsKeys.enableGitProxy)) return direct;
    return kPublicBuild ? ghProxy : hk;
  }

  @override
  String get label => switch (this) {
    hk => '香港镜像',
    ghProxy => 'gh-proxy',
    ghfast => 'ghfast',
    gitcode => 'GitCode',
    direct => '直连',
  };

  @override
  String get description => switch (this) {
    hk => '默认镜像',
    ghProxy => kPublicBuild ? '默认镜像' : '公共镜像',
    ghfast => '备用镜像',
    gitcode => '国内镜像',
    direct => '访问 GitHub',
  };
}
