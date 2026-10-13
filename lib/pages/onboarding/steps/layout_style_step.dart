import 'package:flutter/material.dart';
import 'package:kazumi/pages/onboarding/onboarding_step_layout.dart';
import 'package:kazumi/pages/settings/layout_settings.dart';

class LayoutStyleStep extends StatelessWidget {
  const LayoutStyleStep({super.key});

  @override
  Widget build(BuildContext context) => const OnboardingStepLayout(
    leading: OnboardingStepIcon(
      icon: Icons.dashboard_customize_rounded,
      shape: OnboardingIconShape.flower,
    ),
    title: '选一个喜欢的布局',
    subtitle: '新版留白多，看着舒服。经典更像改版前，排得密，一屏能看到更多番剧。',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutStylePicker(),
        OnboardingHint(text: '之后也可以在「我的 → 外观设置」里换。'),
      ],
    ),
  );
}
