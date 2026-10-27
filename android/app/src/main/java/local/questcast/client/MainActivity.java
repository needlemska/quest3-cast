package local.questcast.client;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * LAN remote for the Quest Cast control app on the PC.
 * Wire protocol: newline-delimited JSON over plain TCP, token handshake first.
 */
public class MainActivity extends Activity {

    private static final int PORT_DEFAULT = 47801;

    private EditText etHost, etPort, etToken;
    private Button btnConnect, btnStart, btnStop, btnMic, btnLens, btnLeft, btnRight, btnBoth, btnCalib;
    private TextView tvConn, tvMic, tvCast, tvDetail, tvLog;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    // the io thread is parked inside the socket read loop, so writes need their own
    // single-thread executor; sharing io would queue them forever
    private final ExecutorService tx = Executors.newSingleThreadExecutor();
    private final List<String> logLines = new ArrayList<>();

    private volatile Socket socket;
    private volatile OutputStream out;
    private volatile Thread readerThread;
    private volatile boolean connected;
    private volatile boolean closing;
    private volatile boolean micOn;
    private volatile boolean castRunning;

    private SharedPreferences prefs;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        etHost = findViewById(R.id.etHost);
        etPort = findViewById(R.id.etPort);
        etToken = findViewById(R.id.etToken);
        btnConnect = findViewById(R.id.btnConnect);
        btnStart = findViewById(R.id.btnStart);
        btnStop = findViewById(R.id.btnStop);
        btnMic = findViewById(R.id.btnMic);
        btnLens = findViewById(R.id.btnLens);
        btnLeft = findViewById(R.id.btnLeft);
        btnRight = findViewById(R.id.btnRight);
        btnBoth = findViewById(R.id.btnBoth);
        btnCalib = findViewById(R.id.btnCalib);
        tvConn = findViewById(R.id.tvConn);
        tvMic = findViewById(R.id.tvMic);
        tvCast = findViewById(R.id.tvCast);
        tvDetail = findViewById(R.id.tvDetail);
        tvLog = findViewById(R.id.tvLog);

        prefs = getSharedPreferences("questcast", Context.MODE_PRIVATE);
        etHost.setText(prefs.getString("host", ""));
        etPort.setText(String.valueOf(getIntPref(prefs, "port", PORT_DEFAULT)));
        etToken.setText(prefs.getString("token", ""));

        btnConnect.setOnClickListener(v -> {
            if (connected) {
                disconnect("отключено вручную");
            } else {
                connect();
            }
        });
        btnStart.setOnClickListener(v -> send("start", null));
        btnStop.setOnClickListener(v -> send("stop", null));
        btnMic.setOnClickListener(v -> send("mic", !micOn));
        btnLens.setOnClickListener(v -> send("lens", !lastLens));
        btnLeft.setOnClickListener(v -> send("eye", "left"));
        btnRight.setOnClickListener(v -> send("eye", "right"));
        btnBoth.setOnClickListener(v -> send("eye", "both"));
        btnCalib.setOnClickListener(v -> send("calibrate", null));

        renderMic(false);
        renderCast(false);
        startImu();

        String host = etHost.getText().toString().trim();
        if (!host.isEmpty()) connect();
    }

    // ------------------------------------------------------------ connection

    private void connect() {
        String host = etHost.getText().toString().trim();
        String token = etToken.getText().toString().trim().toUpperCase();
        int port;
        try {
            port = Integer.parseInt(etPort.getText().toString().trim());
        } catch (NumberFormatException e) {
            port = PORT_DEFAULT;
        }
        if (host.isEmpty() || token.isEmpty()) {
            log("укажи адрес ПК и токен");
            return;
        }
        prefs.edit()
                .putString("host", host)
                .putInt("port", port)
                .putString("token", token)
                .apply();

        setConnecting(true);
        final String fHost = host, fToken = token;
        final int fPort = port;

        io.execute(() -> {
            // retry forever: the PC app restarts often (a rebuild, a config change), and
            // the headset is usually already on someone's head with the app in front
            while (!closing) {
                try {
                    Socket s = new Socket();
                    s.connect(new InetSocketAddress(fHost, fPort), 5000);
                    s.setTcpNoDelay(true);
                    socket = s;
                    out = s.getOutputStream();
                    connected = true;
                    ui.post(() -> setConnecting(false));

                    BufferedReader reader = new BufferedReader(
                            new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
                    String line;
                    while ((line = reader.readLine()) != null) {
                        handleLine(line);
                    }
                    throw new IOException("сервер закрыл соединение");
                } catch (Exception e) {
                    final String message = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
                    ui.post(() -> disconnect("нет связи: " + message + " (повторяю)"));
                    try {
                        Thread.sleep(2000);
                    } catch (InterruptedException ignored) {
                        return;
                    }
                }
            }
        });
    }

    private void disconnect(String reason) {
        connected = false;
        try {
            if (socket != null) socket.close();
        } catch (IOException ignored) {
        }
        socket = null;
        out = null;
        ui.post(() -> {
            tvConn.setText(reason);
            btnConnect.setText("ПОДКЛЮЧИТЬСЯ");
            renderMic(micOn);
            renderCast(castRunning);
        });
        log(reason);
    }

    private void setConnecting(boolean busy) {
        tvConn.setText(busy ? "подключаюсь…" : "не подключено");
        btnConnect.setText(busy ? "ОТМЕНА" : "ПОДКЛЮЧИТЬСЯ");
    }

    // -------------------------------------------------------------- commands

    private boolean lastLens = true;

    // ------------------------------------------------------------ IMU -> ПК
    // A normal 2D app cannot get the headset pose (VrApi/OpenXR own it), but the
    // vendor IMU sensor is visible and its first three payload values are gravity
    // in m/s^2, so roll about the view axis is measurable here.
    private android.hardware.SensorManager sensorManager;
    private volatile double imuRoll;
    private volatile double imuPitch;
    private volatile boolean imuSeen;
    private volatile long lastTiltSent;
    private int tiltLogged;
    private int imuEvents;
    private final android.hardware.SensorEventListener imuListener =
            new android.hardware.SensorEventListener() {
                @Override
                public void onSensorChanged(android.hardware.SensorEvent event) {
                    if (event.values.length < 4) return;
                    double ax = event.values[1];
                    double ay = event.values[2];
                    double az = event.values[3];
                    double g = Math.sqrt(ax * ax + ay * ay + az * az);
                    if (++imuEvents % 400 == 0) {
                        android.util.Log.i("QCTILT", "ev n=" + imuEvents + " g=" + Math.round(g * 100) / 100.0
                                + " ax=" + Math.round(ax * 100) / 100.0
                                + " ay=" + Math.round(ay * 100) / 100.0
                                + " az=" + Math.round(az * 100) / 100.0);
                    }
                    if (g < 1.0) return;
                    // roll is the rotation about the view axis (device z): the angle of
                    // gravity inside the screen plane, i.e. atan2(x, -y). The earlier
                    // atan2(x, z) treated the view axis as "up" and produced nonsense
                    // when the headset lay on its back, where gravity sits on y.
                    imuRoll = Math.toDegrees(Math.atan2(ax, -ay));
                    imuPitch = Math.toDegrees(Math.atan2(az, Math.hypot(ax, ay)));
                    imuSeen = true;
                    sendTilt();
                }

                @Override
                public void onAccuracyChanged(android.hardware.Sensor sensor, int accuracy) {
                }
            };

    private void startImu() {
        sensorManager = (android.hardware.SensorManager) getSystemService(SENSOR_SERVICE);
        if (sensorManager == null) return;
        for (android.hardware.Sensor sensor : sensorManager.getSensorList(android.hardware.Sensor.TYPE_ALL)) {
            String name = sensor.getName() == null ? "" : sensor.getName().toLowerCase();
            String stringType = sensor.getStringType();
            boolean looksLikeImu = name.contains("imu")
                    || (stringType != null && stringType.contains("hmd_imu"));
            if (looksLikeImu) {
                boolean ok = sensorManager.registerListener(imuListener, sensor,
                        android.hardware.SensorManager.SENSOR_DELAY_GAME);
                // the vendor sensor reports its whole calibration JSON as the name, so
                // only a short prefix is logged, and the result goes first
                String shortName = sensor.getName() == null ? "?" : sensor.getName();
                if (shortName.length() > 40) shortName = shortName.substring(0, 40);
                android.util.Log.i("QCTILT", "reg=" + ok + " name=" + shortName);
                log("IMU " + shortName + " -> " + (ok ? "читаю" : "не открылся"));
            }
        }
    }

    /** Push roll/pitch at most 4 times a second; the PC applies it to the shader. */
    private void sendTilt() {
        if (tiltLogged < 4) {
            android.util.Log.i("QCTILT", "enter connected=" + connected + " out=" + (out != null)
                    + " seen=" + imuSeen + " events=" + imuEvents);
        }
        if (!connected || out == null || !imuSeen) {
            if (imuEvents % 800 == 0) {
                android.util.Log.i("QCTILT", "skip connected=" + connected
                        + " out=" + (out != null) + " seen=" + imuSeen);
            }
            return;
        }
        long now = System.currentTimeMillis();
        if (now - lastTiltSent < 250) return;
        lastTiltSent = now;
        // sensor callbacks land on the UI thread, and Android forbids socket writes
        // there (NetworkOnMainThreadException), so the write itself is queued
        tx.execute(this::sendTiltNow);
    }

    private void sendTiltNow() {
        try {
            JSONObject msg = new JSONObject();
            msg.put("type", "tilt");
            msg.put("roll", Math.round(imuRoll * 10.0) / 10.0);
            msg.put("pitch", Math.round(imuPitch * 10.0) / 10.0);
            byte[] bytes = (msg.toString() + "\n").getBytes(StandardCharsets.UTF_8);
            synchronized (MainActivity.this) {
                out.write(bytes);
                out.flush();
            }
            if (tiltLogged++ < 3) {
                android.util.Log.i("QCTILT", "tilt sent " + msg);
            }
        } catch (Exception e) {
            android.util.Log.i("QCTILT", "tilt send failed: " + e);
        }
    }

    private void send(String cmd, Object value) {
        if (!connected || out == null) {
            log("нет связи с ПК");
            return;
        }
        try {
            JSONObject msg = new JSONObject();
            msg.put("type", "cmd");
            msg.put("cmd", cmd);
            if (value != null) msg.put("value", value);
            byte[] bytes = (msg.toString() + "\n").getBytes(StandardCharsets.UTF_8);
            synchronized (MainActivity.this) {
                out.write(bytes);
                out.flush();
            }
            log("→ " + cmd + (value == null ? "" : " " + value));
        } catch (Exception e) {
            log("ошибка отправки: " + e.getMessage());
            disconnect("нет связи");
        }
    }

    // ----------------------------------------------------------------- parse

    private void handleLine(String line) {
        try {
            JSONObject msg = new JSONObject(line);
            String type = msg.optString("type");

            switch (type) {
                case "hello":
                    sendAuth();
                    break;
                case "auth":
                    if (msg.optBoolean("ok")) {
                        ui.post(() -> {
                            tvConn.setText("подключено к ПК");
                            btnConnect.setText("ОТКЛЮЧИТЬ");
                        });
                        log("авторизация ок");
                    } else {
                        disconnect("неверный токен");
                    }
                    break;
                case "state":
                    renderState(msg.optJSONObject("state"));
                    break;
                case "ack":
                    log((msg.optBoolean("ok") ? "ok " : "fail ") + msg.optString("cmd")
                            + (msg.optString("message").isEmpty() ? "" : " — " + msg.optString("message")));
                    break;
                case "error":
                    log("ошибка: " + msg.optString("message"));
                    break;
                default:
                    log("? " + type);
            }
        } catch (Exception e) {
            log("плохой ответ: " + e.getMessage());
        }
    }

    private void sendAuth() {
        try {
            String token = etToken.getText().toString().trim().toUpperCase();
            JSONObject msg = new JSONObject();
            msg.put("type", "auth");
            msg.put("token", token);
            synchronized (MainActivity.this) {
                out.write((msg.toString() + "\n").getBytes(StandardCharsets.UTF_8));
                out.flush();
            }
        } catch (Exception e) {
            disconnect("ошибка авторизации");
        }
    }

    private void renderState(JSONObject st) {
        if (st == null) return;
        micOn = st.optBoolean("mic");
        castRunning = st.optBoolean("running");
        lastLens = st.optBoolean("lens", true);
        String device = st.optString("device", "?");
        int fps = st.optInt("fps");
        double mbps = st.optDouble("mbps", 0);
        String eye = st.optString("eye", "left");

        ui.post(() -> {
            renderMic(micOn);
            renderCast(castRunning);
            tvCast.setText(castRunning
                    ? (fps > 0 ? "КАСТ\n" + fps + " fps" : "КАСТ\nON")
                    : "КАСТ\nOFF");
            tvCast.setBackgroundColor(castRunning ? 0xFF14351F : 0xFF1B1F27);
            tvCast.setTextColor(castRunning ? 0xFF3DDC97 : 0xFF8B93A3);

            btnMic.setText(micOn ? "МИК ВЫКЛ" : "МИК ВКЛ");
            btnLens.setText(lastLens ? "ЛИНЗА ВКЛ" : "ЛИНЗА ВЫКЛ");

            String eyeText = eye.equals("right") ? "правый" : eye.equals("both") ? "оба" : "левый";
            tvDetail.setText(
                    "шлем: " + device
                            + "\nканал: " + mbps + " Mb/s · глаз: " + eyeText
                            + "\nнаклон: " + st.optDouble("tilt") + "° · плеер: " + st.optString("player")
                            + "\nпрошло: " + st.optString("daemonUp") + " / перезапусков " + st.optInt("restarts"));
        });
    }

    private void renderMic(boolean on) {
        tvMic.setText(on ? "МИК\nON" : "МИК\nOFF");
        tvMic.setTextColor(on ? 0xFFFF6B6B : 0xFF8B93A3);
        tvMic.setBackgroundColor(on ? 0xFF5A1C22 : 0xFF1B1F27);
    }

    private void renderCast(boolean on) {
        if (!on) {
            tvCast.setText("КАСТ\nOFF");
            tvCast.setTextColor(0xFF8B93A3);
            tvCast.setBackgroundColor(0xFF1B1F27);
        }
    }

    /**
     * SharedPreferences hands back whatever type was written, and a value stored as a
     * string used to crash the app with ClassCastException the moment it started.
     */
    private static int getIntPref(SharedPreferences prefs, String key, int fallback) {
        try {
            Object raw = prefs.getAll().get(key);
            if (raw instanceof Integer) return (Integer) raw;
            if (raw instanceof Number) return ((Number) raw).intValue();
            if (raw != null) {
                String s = String.valueOf(raw).trim();
                if (!s.isEmpty()) return Integer.parseInt(s);
            }
        } catch (Exception ignored) {
        }
        return fallback;
    }

    private void log(String line) {
        ui.post(() -> {
            logLines.add(line);
            while (logLines.size() > 8) logLines.remove(0);
            tvLog.setText(String.join("\n", logLines));
            tvDetail.setVisibility(View.VISIBLE);
        });
    }

    @Override
    protected void onDestroy() {
        closing = true;
        if (sensorManager != null) {
            sensorManager.unregisterListener(imuListener);
        }
        super.onDestroy();
        connected = false;
        try {
            if (socket != null) socket.close();
        } catch (IOException ignored) {
        }
        io.shutdownNow();
    }
}
