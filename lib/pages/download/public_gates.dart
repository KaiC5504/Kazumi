import 'package:kazumi/build_flavor.dart';

/// Cloud bake and library upload talk to the owner's servers, so public
/// builds hide them. Everything else keeps its `canBake` gate.
bool showCloudUi(bool canBake) => !kPublicBuild && canBake;
