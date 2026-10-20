import 'package:flutter/material.dart';

import 'state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  runApp(MaterialApp(
    home: ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        body: Center(child: Text(state.ready ? 'Лоцман: ${state.visibleCount} узлов' : 'Лоцман')),
      ),
    ),
  ));
  state.init();
}
