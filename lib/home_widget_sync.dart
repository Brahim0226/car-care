import 'package:home_widget/home_widget.dart';

import 'l10n.dart';
import 'main.dart';

/// يحدّث ودجت الشاشة الرئيسية بأقرب صيانة مستحقة للسيارة الحالية
Future<void> updateHomeWidget(Store store) async {
  try {
    final car = store.car;
    Item? best;
    Status? bestSt;
    var urgent = 0;
    for (final it in car.items) {
      final st = car.statusOf(it);
      if (st.level == Level.overdue || st.level == Level.soon) urgent++;
      if (st.level == Level.none) continue;
      if (best == null || st.level.index < bestSt!.level.index) {
        best = it;
        bestSt = st;
      }
    }
    String title;
    String status;
    int level;
    if (best == null) {
      title = t('أضف أول صيانة', 'Ajoutez un entretien');
      status = t('لم تُسجَّل أي صيانة بعد', 'Aucun entretien enregistré');
      level = 3;
    } else if (bestSt!.level == Level.ok) {
      title = t('كل شيء بخير ✅', 'Tout va bien ✅');
      status = '${best.label}: ${bestSt.text}';
      level = 2;
    } else {
      title = best.label;
      status = bestSt.text + (urgent > 1 ? t(' (+${urgent - 1} أخرى)', ' (+${urgent - 1} autres)') : '');
      level = bestSt.level == Level.overdue ? 0 : 1;
    }
    final n = DateTime.now();
    await HomeWidget.saveWidgetData<String>('w_car', car.label);
    await HomeWidget.saveWidgetData<String>('w_title', title);
    await HomeWidget.saveWidgetData<String>('w_status', status);
    await HomeWidget.saveWidgetData<int>('w_level', level);
    await HomeWidget.saveWidgetData<String>(
        'w_updated', t('آخر تحديث: ${n.day}/${n.month}', 'Mis à jour : ${n.day}/${n.month}'));
    await HomeWidget.updateWidget(androidName: 'CarWidgetProvider');
  } catch (_) {}
}
