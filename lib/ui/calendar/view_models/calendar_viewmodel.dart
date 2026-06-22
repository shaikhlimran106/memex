import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import 'package:memex/domain/models/calendar_model.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/utils/result.dart';

/// ViewModel for the Calendar page. Holds month cache, selected date,
/// and delegates data to [MemexRouter].
class CalendarViewModel extends ChangeNotifier {
  CalendarViewModel({
    required MemexRouter router,
    required DateTime initialDate,
  })  : _router = router,
        _selectedDate = initialDate,
        _focusedMonth = DateTime(initialDate.year, initialDate.month);

  final MemexRouter _router;

  DateTime _selectedDate;
  DateTime _focusedMonth;

  /// Cache: 'yyyy-MM' -> List<CalendarDay>
  final Map<String, List<CalendarDay>> monthDataCache = {};
  bool isLoading = false;

  DateTime get selectedDate => _selectedDate;
  DateTime get focusedMonth => _focusedMonth;

  void setSelectedDate(DateTime date) {
    if (_selectedDate == date) return;
    _selectedDate = date;
    notifyListeners();
  }

  void setFocusedMonth(DateTime month) {
    if (_focusedMonth.year == month.year &&
        _focusedMonth.month == month.month) {
      return;
    }
    _focusedMonth = month;
    if (_selectedDate.year != month.year ||
        _selectedDate.month != month.month) {
      _selectedDate = DateTime(month.year, month.month, 1);
    }
    notifyListeners();
  }

  Future<void> fetchMonthData(DateTime month) async {
    final key = DateFormat('yyyy-MM').format(month);
    if (monthDataCache.containsKey(key)) {
      notifyListeners();
      return;
    }

    isLoading = true;
    notifyListeners();
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 1)
        .subtract(const Duration(seconds: 1));
    final result = await _router.fetchCalendarData(
      start.millisecondsSinceEpoch ~/ 1000,
      end.millisecondsSinceEpoch ~/ 1000,
    );
    result.when(
      onOk: (data) => monthDataCache[key] = data,
      onError: (_, __) {},
    );
    isLoading = false;
    notifyListeners();
  }

  List<CalendarCard> getSelectedDayCards() {
    final key = DateFormat('yyyy-MM').format(_focusedMonth);
    final days = monthDataCache[key];
    if (days == null) return [];

    try {
      final dayData = days.firstWhere((d) {
        final date =
            DateTime.fromMillisecondsSinceEpoch(d.timestamp * 1000).toLocal();
        return date.year == _selectedDate.year &&
            date.month == _selectedDate.month &&
            date.day == _selectedDate.day;
      });
      return dayData.cards;
    } catch (_) {
      return [];
    }
  }

  int getCardCountForDay(DateTime date) {
    final key = DateFormat('yyyy-MM').format(date);
    final days = monthDataCache[key];
    if (days == null) return 0;

    try {
      final dayData = days.firstWhere((d) {
        final dDate =
            DateTime.fromMillisecondsSinceEpoch(d.timestamp * 1000).toLocal();
        return dDate.year == date.year &&
            dDate.month == date.month &&
            dDate.day == date.day;
      });
      return dayData.total;
    } catch (_) {
      return 0;
    }
  }
}
