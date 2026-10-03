import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/download/download_page.dart';
import 'package:kazumi/services/upscale/upscale_controller.dart';
import 'package:kazumi/pages/download/download_controller.dart';

final downloadModule = createModule(
  path: '/download',
  register: (c) {
    c.route(
      '/',
      child: (context, state) => DownloadPage(
        controller: inject<DownloadController>(),
        upscaleController: inject<UpscaleController>(),
      ),
    );
  },
);
