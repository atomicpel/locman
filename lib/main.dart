import 'package:flutter/material.dart';

import 'engine/win_core.dart';
import 'state.dart';
import 'ui/shell.dart';

void main(List<String> args) {
  WinCore.args = args;
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  runApp(LocmanApp(state: state));
  state.init();
}
