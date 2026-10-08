import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/presentation/boundary_turn_controller.dart';

void main() {
  test('requires a deliberate second boundary gesture', () {
    final BoundaryTurnController controller = BoundaryTurnController();
    final DateTime start = DateTime.utc(2026, 7, 20);

    expect(controller.register(1, start), isFalse);
    expect(
      controller.register(1, start.add(const Duration(milliseconds: 200))),
      isFalse,
    );
    expect(
      controller.register(1, start.add(const Duration(milliseconds: 500))),
      isTrue,
    );
  });

  test('opposite and expired intent arm instead of turning', () {
    final BoundaryTurnController controller = BoundaryTurnController();
    final DateTime start = DateTime.utc(2026, 7, 20);

    expect(controller.register(1, start), isFalse);
    expect(
      controller.register(-1, start.add(const Duration(milliseconds: 500))),
      isFalse,
    );
    expect(
      controller.register(-1, start.add(const Duration(milliseconds: 3000))),
      isFalse,
    );
  });
}
