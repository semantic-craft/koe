import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/util/off_ui.dart';

void main() {
  setUp(() => offUiFallbacks = 0);

  test('大输入在后台 isolate 执行，小输入留在当前 isolate', () async {
    final here = Isolate.current.debugName;

    final large = await runOffUi(
      () => Isolate.current.debugName,
      size: 10,
      threshold: 5,
      debugName: 'large-input',
    );
    final small = await runOffUi(
      () => Isolate.current.debugName,
      size: 1,
      threshold: 5,
    );

    expect(large, 'large-input');
    expect(small, here);
    expect(offUiFallbacks, 0);
  });

  test('带不能跨 isolate 的值时退回当前 isolate 执行并计数', () async {
    final port = ReceivePort();
    addTearDown(port.close);

    final result = await runOffUi(
      () => port.sendPort.hashCode == 0 ? -1 : 42,
      size: 10,
      threshold: 5,
    );

    expect(result, 42);
    expect(offUiFallbacks, 1);
  });
}
