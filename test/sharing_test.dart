import 'package:flutter_test/flutter_test.dart';
import 'package:otda/src/data/models.dart';

void main() {
  test('a project membership reads roles, members, groups and pending invitations', () {
    final membership = ProjectMembership({
      'projectId': 'p1',
      'role': 'admin',
      'ownerId': 'u1',
      'members': [
        {'userId': 'u1', 'name': 'Ada', 'email': 'ada@example.com', 'role': 'owner'},
        {
          'userId': 'u2',
          'name': 'Grace',
          'email': 'grace@example.com',
          'role': 'editor',
          'avatarVersion': 3,
          'via': [
            {'id': 'g1', 'name': 'Gardeners'},
          ],
        },
      ],
      'grants': [
        {'groupId': 'g1', 'name': 'Gardeners', 'role': 'viewer'},
      ],
      'pending': [
        {'email': 'linus@example.com', 'role': 'viewer'},
      ],
    });

    expect(membership.isShared, isTrue);
    expect(membership.canManage, isTrue);
    expect(membership.members.map((m) => m.role), ['owner', 'editor']);
    expect(membership.members.last.avatarVersion, 3);
    expect(membership.members.last.via.single.name, 'Gardeners');
    expect(membership.grants.single.role, 'viewer');
    expect(membership.pending.single['email'], 'linus@example.com');
  });

  test('a one-person membership is not shared', () {
    final membership = ProjectMembership({
      'projectId': 'p2',
      'role': 'owner',
      'ownerId': 'u1',
      'members': [
        {'userId': 'u1', 'name': 'Ada', 'email': 'ada@example.com', 'role': 'owner'},
      ],
    });
    expect(membership.isShared, isFalse);
    expect(membership.isOwner, isTrue);
    expect(membership.pending, isEmpty);
    expect(membership.grants, isEmpty);
  });
}
