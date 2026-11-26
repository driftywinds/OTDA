import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/kept.dart';
import 'package:otda/src/data/models.dart';

Task task(String id, {String? parent, bool done = false, bool deleted = false}) => Task(id, {
      'parent_id': ?parent,
      if (done) 'completed_at': 1,
      if (deleted) 'deleted_at': 1,
    });

void main() {
  test('open children under a completed parent are kept, at any depth', () {
    final tasks = [
      task('parent', done: true),
      task('child', parent: 'parent'),
      task('grandchild', parent: 'child'),
      task('finished', parent: 'parent', done: true),
      task('loose'),
    ];
    expect(keptIds(tasks), {'child', 'grandchild'});
    expect(withoutKept(tasks).map((t) => t.id), ['parent', 'finished', 'loose']);
  });

  test('a deleted ancestor ends the walk', () {
    final tasks = [
      task('parent', done: true, deleted: true),
      task('child', parent: 'parent'),
    ];
    expect(keptIds(tasks), isEmpty);
  });

  test('a missing ancestor or a cycle does not keep anything', () {
    expect(keptIds([task('child', parent: 'gone')]), isEmpty);
    expect(
      keptIds([
        task('a', parent: 'b'),
        task('b', parent: 'a'),
      ]),
      isEmpty,
    );
  });
}
