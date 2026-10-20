import 'package:flutter/material.dart';

import 'state.dart';
import 'ui/shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  runApp(LocmanApp(state: state));
  state.init();
}
