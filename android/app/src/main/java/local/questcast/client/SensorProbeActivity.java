package local.questcast.client;

import android.app.Activity;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Bundle;
import android.util.Log;

/**
 * Diagnostic activity: it prints every sensor the framework exposes to a normal
 * (non-VR) app and, if the headset IMU is visible, dumps a few raw events.
 *
 * The 2D Android layer on a Quest is not the same thing as the VR runtime: the
 * HMD pose normally lives behind VrApi/OpenXR, so whether a plain activity can
 * see the IMU has to be measured instead of assumed.
 */
public class SensorProbeActivity extends Activity implements SensorEventListener {

    private static final String TAG = "QCSENSOR";
    private static final int MAX_EVENTS = 24;

    private int events;
    private SensorManager manager;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        manager = (SensorManager) getSystemService(SENSOR_SERVICE);
        if (manager == null) {
            Log.i(TAG, "no SensorManager");
            finish();
            return;
        }

        for (Sensor sensor : manager.getSensorList(Sensor.TYPE_ALL)) {
            Log.i(TAG, "sensor name=" + sensor.getName()
                    + " type=" + sensor.getType()
                    + " stringType=" + sensor.getStringType()
                    + " vendor=" + sensor.getVendor()
                    + " minDelay=" + sensor.getMinDelay()
                    + " maxRange=" + sensor.getMaximumRange());
        }

        int[] wanted = {
                Sensor.TYPE_ACCELEROMETER,
                Sensor.TYPE_GYROSCOPE,
                Sensor.TYPE_ROTATION_VECTOR,
                Sensor.TYPE_GAME_ROTATION_VECTOR,
                Sensor.TYPE_GRAVITY,
        };
        for (int type : wanted) {
            Sensor sensor = manager.getDefaultSensor(type);
            Log.i(TAG, "standard type " + type + " -> " + (sensor == null ? "null" : sensor.getName()));
        }

        for (Sensor sensor : manager.getSensorList(Sensor.TYPE_ALL)) {
            String stringType = sensor.getStringType();
            boolean looksLikeImu = sensor.getName().toLowerCase().contains("imu")
                    || (stringType != null && stringType.contains("hmd_imu"));
            if (looksLikeImu) {
                boolean ok = manager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_GAME);
                Log.i(TAG, "registered on " + sensor.getName() + " -> " + ok);
            }
        }

        android.os.Handler handler = new android.os.Handler();
        handler.postDelayed(() -> {
            Log.i(TAG, "probe done, events=" + events);
            finish();
        }, 6000);
    }

    @Override
    public void onSensorChanged(SensorEvent event) {
        if (events++ >= MAX_EVENTS) {
            return;
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < event.values.length; i++) {
            if (i > 0) sb.append(", ");
            sb.append(String.format(java.util.Locale.US, "%.4f", event.values[i]));
        }
        Log.i(TAG, "event type=" + event.sensor.getType() + " n=" + event.values.length + " [" + sb + "]");
    }

    @Override
    public void onAccuracyChanged(Sensor sensor, int accuracy) {
    }

    @Override
    protected void onDestroy() {
        if (manager != null) {
            manager.unregisterListener(this);
        }
        super.onDestroy();
    }
}
