#!/bin/bash
set -e
cat > settings.gradle.kts <<'__EOF__'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "CellMapper"
include(":app")
__EOF__
cat > build.gradle.kts <<'__EOF__'
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
__EOF__
cat > gradle.properties <<'__EOF__'
org.gradle.jvmargs=-Xmx2g
android.useAndroidX=true
kotlin.code.style=official
__EOF__
mkdir -p app
cat > app/build.gradle.kts <<'__EOF__'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
dependencies {
    implementation("org.osmdroid:osmdroid-android:6.1.18")
}
android {
    namespace = "com.example.cellmapper"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.example.cellmapper"
        minSdk = 29
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
__EOF__
mkdir -p app/src/main
cat > app/src/main/AndroidManifest.xml <<'__EOF__'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.READ_PHONE_STATE" />
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <application
        android:label="Cell Mapper"
        android:allowBackup="false"
        android:supportsRtl="true"
        android:theme="@android:style/Theme.DeviceDefault.NoActionBar">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
__EOF__
mkdir -p app/src/main/java/com/example/cellmapper
cat > app/src/main/java/com/example/cellmapper/MainActivity.kt <<'__EOF__'
package com.example.cellmapper

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Point
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telephony.CellIdentityNr
import android.telephony.CellInfo
import android.telephony.CellInfoGsm
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellInfoWcdma
import android.telephony.CellSignalStrengthNr
import android.telephony.TelephonyManager
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Overlay
import org.osmdroid.views.overlay.ScaleBarOverlay
import java.util.Locale
import kotlin.math.*

class Sample(val lat: Double, val lon: Double, val x: Double, val y: Double, val dbm: Int)

class Tower(val key: String, val color: Int) {
    val samples = ArrayList<Sample>()
    var best = -200
    var hasEst = false
    var estLat = 0.0
    var estLon = 0.0
}

class DataOverlay(
    private val towers: () -> Collection<Tower>,
    private val me: () -> GeoPoint?
) : Overlay() {
    private val p = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pt = Point()

    override fun draw(c: Canvas, osmv: MapView, shadow: Boolean) {
        if (shadow) return
        val proj = osmv.projection
        p.style = Paint.Style.FILL
        for (t in towers()) {
            for (s in t.samples) {
                proj.toPixels(GeoPoint(s.lat, s.lon), pt)
                p.color = t.color
                p.alpha = (80 + 175 * ((s.dbm + 120).coerceIn(0, 60) / 60f)).toInt()
                c.drawCircle(pt.x.toFloat(), pt.y.toFloat(), 8f, p)
            }
        }
        for (t in towers()) {
            if (!t.hasEst) continue
            proj.toPixels(GeoPoint(t.estLat, t.estLon), pt)
            val x = pt.x.toFloat(); val y = pt.y.toFloat()
            p.style = Paint.Style.STROKE; p.strokeWidth = 6f; p.color = Color.BLACK
            c.drawCircle(x, y, 28f, p)
            p.style = Paint.Style.FILL; p.color = t.color
            c.drawCircle(x, y, 16f, p)
            p.color = Color.BLACK; p.textSize = 30f
            c.drawText(t.key, x + 34f, y + 10f, p)
        }
        me()?.let {
            proj.toPixels(it, pt)
            p.style = Paint.Style.FILL; p.color = Color.rgb(0, 120, 255)
            c.drawCircle(pt.x.toFloat(), pt.y.toFloat(), 13f, p)
        }
    }
}

class MainActivity : Activity() {
    private val towers = LinkedHashMap<String, Tower>()
    private val palette = intArrayOf(
        Color.rgb(230, 60, 40), Color.rgb(30, 160, 80), Color.rgb(40, 100, 220),
        Color.rgb(240, 170, 0), Color.rgb(160, 60, 190), Color.rgb(0, 170, 180)
    )
    private var lat0 = Double.NaN
    private var lon0 = 0.0
    private var loc: Location? = null
    private var me: GeoPoint? = null
    private var running = false
    private var centered = false
    private var lastTouch = 0L
    private var lastSave = 0L
    private val handler = Handler(Looper.getMainLooper())

    private lateinit var tm: TelephonyManager
    private lateinit var lm: LocationManager
    private lateinit var status: TextView
    private lateinit var list: TextView
    private lateinit var map: MapView
    private lateinit var toggle: Button

    private val locListener = object : LocationListener {
        override fun onLocationChanged(l: Location) { loc = l }
        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, s: Int, e: Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            poll()
            handler.postDelayed(this, 2000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Configuration.getInstance().load(applicationContext, getSharedPreferences("osm", MODE_PRIVATE))
        Configuration.getInstance().userAgentValue = packageName
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        tm = getSystemService(TELEPHONY_SERVICE) as TelephonyManager
        lm = getSystemService(LOCATION_SERVICE) as LocationManager

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(18, 22, 28))
            setPadding(24, 56, 24, 24)
        }
        status = TextView(this).apply {
            setTextColor(Color.WHITE); textSize = 14f
            text = "לחץ \"התחל מדידה\" והסתובב סביב האזור"
        }
        map = MapView(this).apply {
            setTileSource(TileSourceFactory.MAPNIK)
            setMultiTouchControls(true)
            controller.setZoom(3.0)
            overlays.add(DataOverlay({ towers.values }, { me }))
            overlays.add(ScaleBarOverlay(this))
            setOnTouchListener { _, _ -> lastTouch = System.currentTimeMillis(); false }
        }
        list = TextView(this).apply { setTextColor(Color.LTGRAY); textSize = 13f }
        val scroll = ScrollView(this).apply { addView(list) }

        toggle = Button(this).apply { text = "התחל מדידה"; setOnClickListener { if (running) stop() else start() } }
        val clear = Button(this).apply { text = "נקה"; setOnClickListener { clearAll() } }
        val export = Button(this).apply { text = "ייצוא CSV"; setOnClickListener { export() } }
        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            val lp = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            addView(toggle, lp); addView(clear, lp); addView(export, lp)
        }

        val mp = ViewGroup.LayoutParams.MATCH_PARENT
        val wc = ViewGroup.LayoutParams.WRAP_CONTENT
        root.addView(status, LinearLayout.LayoutParams(mp, wc))
        root.addView(map, LinearLayout.LayoutParams(mp, 0, 1f))
        root.addView(scroll, LinearLayout.LayoutParams(mp, 0, 0.7f))
        root.addView(buttons, LinearLayout.LayoutParams(mp, wc))
        setContentView(root)

        load()
        if (towers.isNotEmpty()) {
            map.controller.setZoom(16.0)
            map.controller.setCenter(GeoPoint(lat0, lon0))
            centered = true
            status.text = "נטענו ${towers.values.sumOf { it.samples.size }} דגימות שמורות"
        }
        refresh()
    }

    override fun onResume() { super.onResume(); map.onResume() }

    override fun onPause() {
        save()
        map.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        stop()
        super.onDestroy()
    }

    private fun hasLocationPermission() =
        checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (hasLocationPermission()) start() else status.text = "נדרשת הרשאת מיקום כדי למדוד אנטנות"
    }

    @SuppressLint("MissingPermission")
    private fun start() {
        if (!hasLocationPermission()) {
            requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.READ_PHONE_STATE), 1)
            return
        }
        lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, locListener)
        running = true
        toggle.text = "עצור"
        status.text = "ממתין לאות GPS…"
        handler.post(tick)
    }

    private fun stop() {
        if (running) {
            try { lm.removeUpdates(locListener) } catch (_: Exception) {}
            save()
        }
        running = false
        handler.removeCallbacks(tick)
        if (::toggle.isInitialized) toggle.text = "התחל מדידה"
    }

    @SuppressLint("MissingPermission")
    private fun poll() {
        try {
            tm.requestCellInfoUpdate(mainExecutor, object : TelephonyManager.CellInfoCallback() {
                override fun onCellInfo(cellInfo: MutableList<CellInfo>) { handle(cellInfo) }
            })
        } catch (e: SecurityException) {
            status.text = "חסרות הרשאות לקריאת נתוני רשת"
        }
    }

    private fun parse(ci: CellInfo): Pair<String, Int>? {
        val key: String
        val dbm: Int
        when {
            ci is CellInfoLte -> {
                val i = ci.cellIdentity
                if (i.ci == Int.MAX_VALUE) return null
                key = "LTE ${i.mccString}-${i.mncString} eNB ${i.ci shr 8}"
                dbm = ci.cellSignalStrength.dbm
            }
            ci is CellInfoNr -> {
                val i = ci.cellIdentity as CellIdentityNr
                if (i.nci == Long.MAX_VALUE) return null
                key = "5G ${i.mccString}-${i.mncString} cell ${i.nci}"
                dbm = (ci.cellSignalStrength as CellSignalStrengthNr).dbm
            }
            ci is CellInfoWcdma -> {
                val i = ci.cellIdentity
                if (i.cid == Int.MAX_VALUE) return null
                key = "3G ${i.mccString}-${i.mncString} cell ${i.cid}"
                dbm = ci.cellSignalStrength.dbm
            }
            ci is CellInfoGsm -> {
                val i = ci.cellIdentity
                if (i.cid == Int.MAX_VALUE) return null
                key = "2G ${i.mccString}-${i.mncString} cell ${i.cid}"
                dbm = ci.cellSignalStrength.dbm
            }
            else -> return null
        }
        if (dbm !in -140..-30) return null
        return Pair(key, dbm)
    }

    private fun toX(lat: Double, lon: Double) = (lon - lon0) * 111320.0 * cos(Math.toRadians(lat0))
    private fun toY(lat: Double) = (lat - lat0) * 110540.0

    private fun handle(cells: List<CellInfo>) {
        if (!running) return
        val l = loc
        if (l == null) { status.text = "ממתין לאות GPS…"; return }
        if (System.currentTimeMillis() - l.time > 10_000 || l.accuracy > 40f) {
            status.text = "ממתין לדיוק GPS טוב יותר (${l.accuracy.toInt()} מ׳)"
            return
        }
        if (lat0.isNaN()) { lat0 = l.latitude; lon0 = l.longitude }
        val x = toX(l.latitude, l.longitude)
        val y = toY(l.latitude)

        val now = HashMap<String, Int>()
        for (ci in cells) {
            val (k, d) = parse(ci) ?: continue
            if (d > (now[k] ?: -999)) now[k] = d
        }
        var added = false
        for ((k, d) in now) {
            val t = towers.getOrPut(k) { Tower(k, palette[towers.size % palette.size]) }
            val last = t.samples.lastOrNull()
            if (last == null || hypot(last.x - x, last.y - y) >= 5.0) {
                t.samples.add(Sample(l.latitude, l.longitude, x, y, d))
                estimate(t)
                added = true
            }
            if (d > t.best) t.best = d
        }

        val g = GeoPoint(l.latitude, l.longitude)
        me = g
        if (!centered) {
            map.controller.setZoom(17.0); map.controller.setCenter(g); centered = true
        } else if (System.currentTimeMillis() - lastTouch > 15_000) {
            map.controller.animateTo(g)
        }
        if (added && System.currentTimeMillis() - lastSave > 15_000) save()
        status.text = "מודד… ${now.size} תאים בטווח | דיוק GPS ${l.accuracy.toInt()} מ׳"
        refresh()
    }

    // ממוצע משוקלל של הדגימות החזקות ביותר (משקל לפי עוצמת אות לינארית)
    private fun estimate(t: Tower) {
        if (t.samples.size < 5) { t.hasEst = false; return }
        val sorted = t.samples.sortedByDescending { it.dbm }
        val top = sorted.take(max(3, (sorted.size * 0.3).toInt()))
        val best = top[0].dbm
        var sw = 0.0; var sla = 0.0; var slo = 0.0
        for (s in top) {
            val w = 10.0.pow((s.dbm - best) / 10.0)
            sw += w; sla += w * s.lat; slo += w * s.lon
        }
        t.estLat = sla / sw
        t.estLon = slo / sw
        t.hasEst = true
    }

    private fun refresh() {
        map.invalidate()
        list.text = towers.values.sortedByDescending { it.samples.size }.joinToString("\n\n") { t ->
            val pos = if (t.hasEst) String.format(Locale.US, "מיקום משוער: %.5f, %.5f", t.estLat, t.estLon)
            else "צריך עוד דגימות (לפחות 5, מנקודות שונות)"
            "● ${t.key}\n   דגימות: ${t.samples.size} | הכי חזק: ${t.best} dBm\n   $pos"
        }
    }

    private fun save() {
        lastSave = System.currentTimeMillis()
        val sb = StringBuilder()
        for (t in towers.values) for (s in t.samples)
            sb.append(t.key).append('|').append(s.lat).append('|').append(s.lon).append('|').append(s.dbm).append('\n')
        getSharedPreferences("data", MODE_PRIVATE).edit().putString("samples", sb.toString()).apply()
    }

    private fun load() {
        val txt = getSharedPreferences("data", MODE_PRIVATE).getString("samples", null) ?: return
        for (line in txt.lineSequence()) {
            val a = line.split('|')
            if (a.size != 4) continue
            val lat = a[1].toDoubleOrNull() ?: continue
            val lon = a[2].toDoubleOrNull() ?: continue
            val dbm = a[3].toIntOrNull() ?: continue
            if (lat0.isNaN()) { lat0 = lat; lon0 = lon }
            val t = towers.getOrPut(a[0]) { Tower(a[0], palette[towers.size % palette.size]) }
            t.samples.add(Sample(lat, lon, toX(lat, lon), toY(lat), dbm))
            if (dbm > t.best) t.best = dbm
        }
        towers.values.forEach { estimate(it) }
    }

    private fun clearAll() {
        towers.clear()
        lat0 = Double.NaN
        getSharedPreferences("data", MODE_PRIVATE).edit().remove("samples").apply()
        refresh()
    }

    private fun export() {
        val sb = StringBuilder("tower,lat,lon,dbm,type\n")
        for (t in towers.values) {
            for (s in t.samples) sb.append("\"${t.key}\",${s.lat},${s.lon},${s.dbm},sample\n")
            if (t.hasEst) sb.append("\"${t.key}\",${t.estLat},${t.estLon},,estimate\n")
        }
        val i = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, sb.toString().take(400_000))
        }
        startActivity(Intent.createChooser(i, "ייצוא CSV"))
    }
}
__EOF__
