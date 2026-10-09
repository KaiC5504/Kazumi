/// Set only by public-release.yaml. Her TestFlight build (codemagic.yaml)
/// never passes it, so personal values stay the defaults.
///
/// Keep this the only read of the flag, and keep it const: a non-const
/// `bool.fromEnvironment` doesn't reliably see the define (false under
/// `flutter test` and in AOT, true under `dart run`).
const bool kPublicBuild = bool.fromEnvironment('KAZUMI_PUBLIC');

const String kForkName = 'Kazumi';
