//!DESCRIPTION Quest 3 lens correction and horizon tilt
//!HOOK MAIN
//!BIND HOOKED
//!SAVE MAIN
//!WIDTH HOOKED.w
//!HEIGHT HOOKED.h

// k1/k2 undo the barrel pre-distortion of the headset compositor,
// ang is the horizon tilt in radians, both come from config.json
#define K1  @K1@
#define K2  @K2@
#define ANG @ANGLE@

// alignment guide: a bright line drawn in OUTPUT space (after the warp), so it
// stays horizontal no matter how the frame is rotated. The client draws the twin
// of this line in the headset; when the two coincide on screen the rotation is
// right. 0 = hidden.
#define GUIDE     @GUIDE@
#define GUIDE_ANG @GUIDEANG@

// One pass: inverse-map every output pixel back to the panel image.
// Mapping is done in aspect corrected space so the radial term stays a circle.
vec4 hook() {
    vec2 size = HOOKED_size;
    float aspect = size.x / size.y;
    vec2 p = HOOKED_pos * 2.0 - 1.0;
    p.x *= aspect;

    float c = cos(ANG), s = sin(ANG);
    vec2 q = vec2(c * p.x - s * p.y, s * p.x + c * p.y);

    // normalise the radius the way ffmpeg's lenscorrection does: r = 1 at the
    // corner of the frame, so K1/K2 mean the same thing in both pipelines
    float d = aspect * aspect + 1.0;
    float r2 = dot(q, q) / d;
    float f = 1.0 + K1 * r2 + K2 * r2 * r2;
    vec2 t = q * f;

    t.x /= aspect;
    vec2 uv = t * 0.5 + 0.5;

    vec4 col;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        col = vec4(0.0, 0.0, 0.0, 1.0);
    else
        col = HOOKED_tex(uv);

    if (GUIDE > 0.5) {
        // same aspect corrected space as above, but the untransformed pixel:
        // the guide must not follow the warp it is meant to verify
        vec2 o = HOOKED_pos * 2.0 - 1.0;
        o.x *= aspect;

        float ca = cos(GUIDE_ANG), sa = sin(GUIDE_ANG);
        float dist = abs(-sa * o.x + ca * o.y);   // distance to the line through the centre
        float along = ca * o.x + sa * o.y;        // position along the line

        float px = 2.0 / size.y;                  // one pixel in these units
        float half = 1.6 * px;

        if (dist < half) col.rgb = vec3(0.15, 0.95, 1.0);

        // ticks: centre cross plus two marks, so a small residual angle is visible
        bool tick = (abs(along) < 2.0 * px) || (abs(abs(along) - 0.45 * aspect) < 1.5 * px);
        if (tick && dist < 9.0 * px) col.rgb = vec3(0.15, 0.95, 1.0);

        // the headset line is drawn by the client; this small mark shows the
        // applied rotation in the corner as a reference for the operator
        if (abs(along - 0.88 * aspect) < 2.5 * px && dist < 5.0 * px) col.rgb = vec3(1.0, 0.72, 0.2);
    }

    return col;
}
