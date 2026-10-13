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
