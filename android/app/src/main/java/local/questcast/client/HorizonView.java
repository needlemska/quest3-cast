package local.questcast.client;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.util.AttributeSet;
import android.view.View;

import java.util.Locale;

/**
 * The headset half of the two-line horizon guide.
 *
 * The line drawn here is the reference: it is fixed to the panel, so in the streamed
 * picture it shows exactly how the panel itself is rotated. The PC draws its own line
 * across the whole streamed frame; the two must be parallel. Rotating the PC line with
 * the nudging buttons until it matches this one - out in the world, not on the desk -
 * removes both the panel cant and the headset roll at the same time.
 */
public class HorizonView extends View {

    private final Paint line = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint tick = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint text = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint halo = new Paint(Paint.ANTI_ALIAS_FLAG);

    private double streamDeg = Double.NaN;
    private double imuDeg = Double.NaN;

    public HorizonView(Context context) {
        super(context);
        init();
    }

    public HorizonView(Context context, AttributeSet attrs) {
        super(context, attrs);
        init();
    }

    private float dp(float v) {
        return v * getResources().getDisplayMetrics().density;
    }

    private void init() {
        line.setColor(0xFF29F2FF);
        line.setStrokeWidth(dp(3));
        line.setStyle(Paint.Style.STROKE);

        halo.setColor(0x3329F2FF);
        halo.setStrokeWidth(dp(16));
        halo.setStyle(Paint.Style.STROKE);

        tick.setColor(0xFF29F2FF);
        tick.setStrokeWidth(dp(2));
        tick.setStyle(Paint.Style.STROKE);

        text.setColor(0xFFCFE6EE);
        text.setTextSize(dp(13));
        text.setTypeface(Typeface.MONOSPACE);
        text.setAntiAlias(true);
    }

    /** Angles come from the PC state push, only shown as numbers for reference. */
    public void setAngles(double stream, double imu) {
        streamDeg = stream;
        imuDeg = imu;
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);

        float w = getWidth();
        float h = getHeight();
        float cy = h / 2f;
        float pad = dp(24);

        canvas.drawLine(pad, cy, w - pad, cy, halo);
        canvas.drawLine(pad, cy, w - pad, cy, line);

        // ticks make it obvious when the two lines converge instead of staying parallel
        float big = dp(18);
        float small = dp(9);
        for (int i = 1; i <= 8; i++) {
            float x = pad + (w - 2 * pad) * i / 9f;
            float len = (i == 4 || i == 5) ? big : small;
            canvas.drawLine(x, cy - len, x, cy + len, tick);
        }

        // centre marker
        tick.setStyle(Paint.Style.FILL);
        canvas.drawCircle(w / 2f, cy, dp(3), tick);
        tick.setStyle(Paint.Style.STROKE);

        String s = "эталон в шлеме   ·   стрим " + deg(streamDeg) + "   ·   IMU " + deg(imuDeg);
        canvas.drawText(s, pad, cy + dp(46), text);

        String hint = "крутите ЛИНИЮ на ПК кнопками -0.5° / +0.5°, пока линии не станут параллельны";
        canvas.drawText(hint, pad, cy + dp(68), text);
    }

    private String deg(double v) {
        if (Double.isNaN(v)) {
            return "—";
        }
        return String.format(Locale.US, "%.1f°", v);
    }
}
