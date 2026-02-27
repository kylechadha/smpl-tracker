import 'package:flutter_test/flutter_test.dart';
import 'package:smpl_tracker/models/habit.dart';
import 'package:smpl_tracker/models/log.dart';
import 'package:smpl_tracker/utils/decay.dart';

/// Helper to create a test habit
Habit _makeHabit({
  String frequencyType = 'weekly',
  int frequencyCount = 3,
}) {
  return Habit(
    id: 'test-habit',
    name: 'Test',
    frequencyType: frequencyType,
    frequencyCount: frequencyCount,
    sortOrder: 0,
    createdAt: DateTime(2025, 1, 1),
    updatedAt: DateTime(2025, 1, 1),
  );
}

/// Helper to create a log for a given date string (YYYY-MM-DD)
Log _makeLog(String dateStr) {
  return Log(
    id: 'test-habit_$dateStr',
    habitId: 'test-habit',
    loggedDate: dateStr,
    createdAt: DateTime.now(),
  );
}

String _fmt(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Generate logs for past weeks to establish a healthy baseline.
/// Creates [count] logs per week for [weeks] weeks before [today].
List<Log> _baselineLogs(DateTime today, {int weeks = 13, int count = 3}) {
  final logs = <Log>[];
  for (int w = 1; w <= weeks; w++) {
    // Go back w weeks, start from that Sunday
    final weekStart = today.subtract(Duration(days: today.weekday % 7 + w * 7));
    for (int d = 0; d < count && d < 7; d++) {
      logs.add(_makeLog(_fmt(weekStart.add(Duration(days: d)))));
    }
  }
  return logs;
}

/// Generate daily logs for a range of days ago, excluding specific days
List<Log> _dailyLogs(DateTime today, {int days = 90, Set<int>? skipDaysAgo}) {
  final logs = <Log>[];
  final skip = skipDaysAgo ?? {};
  for (int i = 0; i < days; i++) {
    if (!skip.contains(i)) {
      logs.add(_makeLog(_fmt(today.subtract(Duration(days: i)))));
    }
  }
  return logs;
}

void main() {
  group('calculateHealth - health cap', () {
    test('health never exceeds 100%', () {
      final habit = _makeHabit(frequencyType: 'daily', frequencyCount: 1);
      final today = DateTime(2026, 2, 26);
      final logs = _dailyLogs(today, days: 90);

      final health = calculateHealth(habit, logs, asOf: today);
      expect(health, equals(100.0));
    });

    test('extra weekly logs beyond target have no effect', () {
      final habit = _makeHabit(frequencyCount: 3);
      // Saturday so the week is complete
      final today = DateTime(2026, 2, 21); // Saturday
      final weekStart = DateTime(2026, 2, 15); // Sunday

      // Baseline + 5 logs this week (target is 3)
      final logs = _baselineLogs(today, count: 3);
      for (int i = 0; i < 5; i++) {
        logs.add(_makeLog(_fmt(weekStart.add(Duration(days: i)))));
      }

      final health = calculateHealth(habit, logs, asOf: today);
      expect(health, lessThanOrEqualTo(100.0));
    });
  });

  group('calculateHealth - mid-week decay for weekly habits', () {
    test('mid-week with 0 logs shows provisional decay', () {
      final habit = _makeHabit(frequencyCount: 3);
      // Wednesday Feb 25 - week started Sunday Feb 22
      final today = DateTime(2026, 2, 25);
      // Provide past-week logs to keep baseline healthy, but nothing this week
      final logs = _baselineLogs(today, count: 3);

      final health = calculateHealth(habit, logs, asOf: today);
      expect(health, lessThan(100.0));
    });

    test('mid-week decay increases as more days pass without logging', () {
      final habit = _makeHabit(frequencyCount: 3);
      // Week starts Sunday Feb 22
      final monday = DateTime(2026, 2, 23);
      final wednesday = DateTime(2026, 2, 25);

      // Same past logs for both
      final logsMonday = _baselineLogs(monday, count: 3);
      final logsWednesday = _baselineLogs(wednesday, count: 3);

      final healthMonday = calculateHealth(habit, logsMonday, asOf: monday);
      final healthWednesday =
          calculateHealth(habit, logsWednesday, asOf: wednesday);

      // Both should be below 100%, and Wednesday should be lower
      expect(healthMonday, lessThan(100.0));
      expect(healthWednesday, lessThan(healthMonday));
    });

    test('logging reduces the mid-week penalty', () {
      final habit = _makeHabit(frequencyCount: 3);
      final today = DateTime(2026, 2, 25); // Wednesday

      final logsNoLog = _baselineLogs(today, count: 3);
      final logsWithLog = List<Log>.from(_baselineLogs(today, count: 3))
        ..add(_makeLog('2026-02-23')); // Logged Monday this week

      final healthNoLogs = calculateHealth(habit, logsNoLog, asOf: today);
      final healthWithLog = calculateHealth(habit, logsWithLog, asOf: today);

      expect(healthWithLog, greaterThan(healthNoLogs));
    });

    test('meeting target mid-week gives recovery, no penalty', () {
      final habit = _makeHabit(frequencyCount: 3);
      final today = DateTime(2026, 2, 25); // Wednesday

      // Past baseline + 3 logs this week (target met)
      final logs = _baselineLogs(today, count: 3);
      logs.add(_makeLog('2026-02-22')); // Sunday
      logs.add(_makeLog('2026-02-23')); // Monday
      logs.add(_makeLog('2026-02-24')); // Tuesday

      final health = calculateHealth(habit, logs, asOf: today);
      expect(health, equals(100.0));
    });

    test('no penalty on first day of week (Sunday)', () {
      final habit = _makeHabit(frequencyCount: 3);
      // Sunday is the first day — date.isAfter(weekStart) is false,
      // so no provisional penalty should apply
      final sunday = DateTime(2026, 2, 22);
      final logs = _baselineLogs(sunday, count: 3);

      final health = calculateHealth(habit, logs, asOf: sunday);
      expect(health, equals(100.0));
    });
  });

  group('calculateHealth - completed week evaluation', () {
    test('completed week with met target gives recovery', () {
      final habit = _makeHabit(frequencyCount: 3);
      // Saturday = end of week
      final today = DateTime(2026, 2, 28);
      final logs = _baselineLogs(today, count: 3);
      // This week's logs (Sun Feb 22 - Sat Feb 28)
      logs.add(_makeLog('2026-02-22'));
      logs.add(_makeLog('2026-02-24'));
      logs.add(_makeLog('2026-02-26'));

      final health = calculateHealth(habit, logs, asOf: today);
      expect(health, equals(100.0));
    });

    test('completed week with missed target causes decay', () {
      final habit = _makeHabit(frequencyCount: 3);
      final today = DateTime(2026, 2, 28); // Saturday
      // Past baseline, but only 2/3 this week
      final logs = _baselineLogs(today, count: 3);
      logs.add(_makeLog('2026-02-22'));
      logs.add(_makeLog('2026-02-24'));

      final health = calculateHealth(habit, logs, asOf: today);
      expect(health, lessThan(100.0));
    });
  });

  group('calculateHealth - daily habits', () {
    test('daily habit decays on missed days', () {
      final habit = _makeHabit(frequencyType: 'daily', frequencyCount: 1);
      final today = DateTime(2026, 2, 26);
      // Skip yesterday AND today — two consecutive misses
      final logs = _dailyLogs(today, days: 90, skipDaysAgo: {0, 1});

      final health = calculateHealth(habit, logs, asOf: today);
      expect(health, lessThan(100.0));
    });

    test('daily habit at 100% after consistent logging', () {
      final habit = _makeHabit(frequencyType: 'daily', frequencyCount: 1);
      final today = DateTime(2026, 2, 26);
      final logs = _dailyLogs(today, days: 90);

      final health = calculateHealth(habit, logs, asOf: today);
      expect(health, equals(100.0));
    });
  });

  group('calculateHealth - mid-week proportional to frequency', () {
    test('higher frequency habits decay faster mid-week', () {
      final today = DateTime(2026, 2, 25); // Wednesday, no logs this week

      final habit3x = _makeHabit(frequencyCount: 3);
      final habit1x = _makeHabit(frequencyCount: 1);

      final logs3x = _baselineLogs(today, count: 3);
      final logs1x = _baselineLogs(today, count: 1);

      final health3x = calculateHealth(habit3x, logs3x, asOf: today);
      final health1x = calculateHealth(habit1x, logs1x, asOf: today);

      // 3x/week should have more decay than 1x/week when behind
      expect(health3x, lessThan(health1x));
    });
  });
}
