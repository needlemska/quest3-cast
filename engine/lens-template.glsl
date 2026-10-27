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

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return vec4(0.0, 0.0, 0.0, 1.0);
    return HOOKED_tex(uv);
}

