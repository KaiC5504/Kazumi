import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/library/library_page.dart';
import 'package:kazumi/services/library/library_controller.dart';

final libraryModule = createModule(
  path: '/library',
  register: (c) {
    c.route(
      '/',
      child: (context, state) =>
          LibraryPage(controller: inject<LibraryController>()),
    );
  },
);
