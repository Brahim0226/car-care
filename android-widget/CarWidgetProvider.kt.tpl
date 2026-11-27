package __PKG__

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider
import __NS__.R

class CarWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { id ->
            val views = RemoteViews(context.packageName, R.layout.car_widget)
            views.setTextViewText(R.id.w_car, widgetData.getString("w_car", "") ?: "")
            views.setTextViewText(R.id.w_title, widgetData.getString("w_title", "صيانة سيارتي") ?: "")
            views.setTextViewText(R.id.w_status, widgetData.getString("w_status", "افتح التطبيق") ?: "")
            views.setTextViewText(R.id.w_updated, widgetData.getString("w_updated", "") ?: "")
            val level = widgetData.getInt("w_level", 3)
            val color = when (level) {
                0 -> Color.parseColor("#C62828")
                1 -> Color.parseColor("#E65100")
                2 -> Color.parseColor("#2E7D32")
                else -> Color.parseColor("#1565C0")
            }
            views.setTextColor(R.id.w_status, color)
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launch != null) {
                val pi = PendingIntent.getActivity(
                    context, 0, launch,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
                views.setOnClickPendingIntent(R.id.widget_root, pi)
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
