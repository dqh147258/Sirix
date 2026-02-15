import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract class BaseViewModel<T> extends StateNotifier<T> {
  BaseViewModel(super.state);
}
