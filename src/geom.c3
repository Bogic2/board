// Pure 2D maths for the board: no GPU or window dependencies, so it can be unit tested.
module tabla::geom;
import std::math, std::collections::list;

alias DVec2 = double[<2>];

const int DISC_SEGMENTS = 20;
// How far a corner may turn before it gets a round join rather than a mitre.
const float SHARP_COS = 0.5f;

struct InkPoint
{
	float x;
	float y;
	float w; // full stroke width at this point
}

// Axis-aligned rectangle in world space.
struct DRect
{
	DVec2 lo;
	DVec2 hi;
}

// What shape of nib the stroke was drawn with.
enum Tip : char
{
	ROUND,
	CHISEL,
	WEDGE,
}

fn float length(Vec2 v) => math::sqrt(v.x * v.x + v.y * v.y);
fn float dot(Vec2 a, Vec2 b) => a.x * b.x + a.y * b.y;
fn Vec2 perp(Vec2 v) => { -v.y, v.x };
fn Vec2 pos_of(InkPoint p) => { p.x, p.y };

fn Vec2 normalize(Vec2 v)
{
	float l = length(v);
	if (l < 1e-12f) return { 1, 0 };
	return v / l;
}

fn DRect rect_of(DVec2 a, DVec2 b)
{
	return {
		.lo = { math::min(a.x, b.x), math::min(a.y, b.y) },
		.hi = { math::max(a.x, b.x), math::max(a.y, b.y) }
	};
}

fn DRect DRect.merge(self, DRect o)
{
	return {
		.lo = { math::min(self.lo.x, o.lo.x), math::min(self.lo.y, o.lo.y) },
		.hi = { math::max(self.hi.x, o.hi.x), math::max(self.hi.y, o.hi.y) }
	};
}

fn bool DRect.contains(self, DVec2 p)
{
	return p.x >= self.lo.x && p.x <= self.hi.x && p.y >= self.lo.y && p.y <= self.hi.y;
}

fn bool DRect.overlaps(self, DRect o)
{
	return self.lo.x <= o.hi.x && self.hi.x >= o.lo.x && self.lo.y <= o.hi.y && self.hi.y >= o.lo.y;
}

fn DVec2 DRect.size(self) => self.hi - self.lo;

fn float dist_to_segment(Vec2 p, Vec2 a, Vec2 b)
{
	Vec2 ab = b - a;
	float len_sq = dot(ab, ab);
	if (len_sq < 1e-18f) return length(p - a);
	float t = math::clamp(dot(p - a, ab) / len_sq, 0.0f, 1.0f);
	return length(p - (a + ab * t));
}

fn InkPoint catmull_rom(InkPoint p0, InkPoint p1, InkPoint p2, InkPoint p3, float t) @local
{
	float t2 = t * t;
	float t3 = t2 * t;
	InkPoint out;
	out.x = 0.5f * (2 * p1.x + (p2.x - p0.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (3 * p1.x - p0.x - 3 * p2.x + p3.x) * t3);
	out.y = 0.5f * (2 * p1.y + (p2.y - p0.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (3 * p1.y - p0.y - 3 * p2.y + p3.y) * t3);
	out.w = p1.w + (p2.w - p1.w) * t;
	return out;
}

<*
 Expands raw input points into a polyline dense enough to look curved. The number of
 subdivisions follows the turning angle, so the result is smooth at any zoom.
*>
fn void flatten(InkPoint[] src, bool smooth, List{InkPoint}* out)
{
	out.clear();
	sz n = src.len;
	if (n == 0) return;
	if (!smooth || n < 3)
	{
		out.push_all(src);
		return;
	}
	out.push(src[0]);
	for (sz i = 0; i + 1 < n; i++)
	{
		InkPoint p0 = src[i > 0 ? i - 1 : 0];
		InkPoint p1 = src[i];
		InkPoint p2 = src[i + 1];
		InkPoint p3 = src[i + 2 < n ? i + 2 : n - 1];
		Vec2 t1 = normalize(pos_of(p2) - pos_of(p0));
		Vec2 t2 = normalize(pos_of(p3) - pos_of(p1));
		float angle = math::acos(math::clamp(dot(t1, t2), -1.0f, 1.0f));
		int steps = math::clamp(1 + (int)(angle / 0.14f), 1, 12);
		for (int s = 1; s <= steps; s++)
		{
			out.push(s == steps ? p2 : catmull_rom(p0, p1, p2, p3, (float)s / steps));
		}
	}
}

fn void push_tri(List{Vec2}* out, Vec2 a, Vec2 b, Vec2 c) @local
{
	out.push(a);
	out.push(b);
	out.push(c);
}

fn void push_quad(List{Vec2}* out, Vec2 a, Vec2 b, Vec2 c, Vec2 d) @local
{
	push_tri(out, a, b, c);
	push_tri(out, c, b, d);
}

fn void push_disc(List{Vec2}* out, Vec2 c, float r) @local
{
	Vec2 prev = { c.x + r, c.y };
	for (int i = 1; i <= DISC_SEGMENTS; i++)
	{
		float a = (float)i / DISC_SEGMENTS * (float)math::PI * 2;
		Vec2 next = { c.x + math::cos(a) * r, c.y + math::sin(a) * r };
		push_tri(out, c, prev, next);
		prev = next;
	}
}

fn void ribbon_round(InkPoint[] p, List{Vec2}* out) @local
{
	sz n = p.len;
	if (n == 1)
	{
		push_disc(out, pos_of(p[0]), p[0].w * 0.5f);
		return;
	}
	push_disc(out, pos_of(p[0]), p[0].w * 0.5f);
	Vec2 prev_l;
	Vec2 prev_r;
	bool have_prev = false;
	for (sz i = 0; i < n; i++)
	{
		Vec2 here = pos_of(p[i]);
		float r = p[i].w * 0.5f;
		Vec2 d_in = normalize(here - pos_of(p[i > 0 ? i - 1 : 0]));
		Vec2 d_out = normalize(pos_of(p[i + 1 < n ? i + 1 : n - 1]) - here);
		if (i == 0) d_in = d_out;
		if (i + 1 == n) d_out = d_in;
		if (dot(d_in, d_out) > SHARP_COS)
		{
			Vec2 middle = normalize(d_in + d_out);
			Vec2 side = perp(middle) * (r / math::max(dot(middle, d_in), 0.5f));
			Vec2 l = here + side;
			Vec2 right = here - side;
			if (have_prev) push_quad(out, prev_l, prev_r, l, right);
			prev_l = l;
			prev_r = right;
			have_prev = true;
			continue;
		}
		// A corner too sharp to mitre: close the ribbon, cover the pivot, restart.
		Vec2 side_in = perp(d_in) * r;
		if (have_prev) push_quad(out, prev_l, prev_r, here + side_in, here - side_in);
		push_disc(out, here, r);
		Vec2 side_out = perp(d_out) * r;
		prev_l = here + side_out;
		prev_r = here - side_out;
		have_prev = true;
	}
	push_disc(out, pos_of(p[n - 1]), p[n - 1].w * 0.5f);
}

// Sweeps a rectangular nib held at a fixed angle, the way a real felt marker behaves.
fn void ribbon_nib(InkPoint[] p, float angle, float aspect, List{Vec2}* out) @local
{
	Vec2 long_axis = { math::cos(angle), math::sin(angle) };
	Vec2 short_axis = perp(long_axis);
	foreach (i, point : p)
	{
		Vec2 here = pos_of(point);
		Vec2 a = long_axis * (point.w * 0.5f);
		Vec2 b = short_axis * (point.w * 0.5f * aspect);
		push_quad(out, here - a - b, here + a - b, here - a + b, here + a + b);
		if (i + 1 == p.len) break;
		Vec2 next = pos_of(p[i + 1]);
		Vec2 na = long_axis * (p[i + 1].w * 0.5f);
		Vec2 nb = short_axis * (p[i + 1].w * 0.5f * aspect);
		// The two diagonals swept along the segment fill the hull of both nib positions.
		push_quad(out, here - a - b, here + a + b, next - na - nb, next + na + nb);
		push_quad(out, here + a - b, here - a + b, next + na - nb, next - na + nb);
	}
}

<*
 Turns ink points into a triangle list. Triangles may overlap: translucent ink is drawn
 through the stencil buffer so that overlap does not show.
*>
fn void tessellate(InkPoint[] src, bool smooth, Tip tip, List{Vec2}* out, List{InkPoint}* scratch)
{
	out.clear();
	flatten(src, smooth, scratch);
	InkPoint[] p = scratch.array_view();
	if (p.len == 0) return;
	switch (tip)
	{
		case ROUND: ribbon_round(p, out);
		case CHISEL: ribbon_nib(p, -0.9f, 0.32f, out);
		case WEDGE: ribbon_nib(p, 1.3f, 0.3f, out);
	}
}

fn InkPoint lerp_point(InkPoint a, InkPoint b, float t) @local
{
	return { a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.w + (b.w - a.w) * t };
}

fn void flush_run(List{InkPoint}* run, List{InkPoint[]}* out) @local
{
	if (run.len() >= 2) out.push(run.to_array(mem));
	run.clear();
}

<*
 Cuts away everything the capsule a->b of radius r touches. Surviving runs are appended
 to `out` as newly allocated slices, which the caller owns.

 @return "true when something was erased; if false `out` is left untouched."
*>
fn bool erase_capsule(InkPoint[] pts, Vec2 a, Vec2 b, float r, List{InkPoint[]}* out)
{
	bool touched = false;
	foreach (p : pts)
	{
		if (dist_to_segment(pos_of(p), a, b) <= r + p.w * 0.5f) touched = true;
	}
	if (!touched)
	{
		// Long segments can pass through the eraser with both ends outside it.
		for (sz i = 0; i + 1 < pts.len && !touched; i++)
		{
			float seg = length(pos_of(pts[i + 1]) - pos_of(pts[i]));
			int steps = math::clamp((int)(seg / math::max(r * 0.5f, 1e-6f)), 1, 256);
			for (int s = 1; s < steps && !touched; s++)
			{
				InkPoint q = lerp_point(pts[i], pts[i + 1], (float)s / steps);
				touched = dist_to_segment(pos_of(q), a, b) <= r + q.w * 0.5f;
			}
		}
	}
	if (!touched) return false;

	List{InkPoint} run;
	run.init(mem);
	defer run.free();
	foreach (i, p : pts)
	{
		if (dist_to_segment(pos_of(p), a, b) <= r + p.w * 0.5f)
		{
			flush_run(&run, out);
		}
		else
		{
			run.push(p);
		}
		if (i + 1 == pts.len) break;
		// Walk the segment so that the cut lands at the edge of the eraser, not at the
		// next stored point.
		float seg = length(pos_of(pts[i + 1]) - pos_of(p));
		int steps = math::clamp((int)(seg / math::max(r * 0.25f, 1e-6f)), 1, 256);
		bool was_inside = false;
		InkPoint last_outside = p;
		for (int s = 1; s < steps; s++)
		{
			InkPoint q = lerp_point(p, pts[i + 1], (float)s / steps);
			bool inside = dist_to_segment(pos_of(q), a, b) <= r + q.w * 0.5f;
			if (inside && !was_inside)
			{
				if (s > 1) run.push(last_outside);
				flush_run(&run, out);
			}
			else if (!inside && was_inside)
			{
				run.push(q);
			}
			was_inside = inside;
			if (!inside) last_outside = q;
		}
	}
	flush_run(&run, out);
	return true;
}

fn int read_u16(char[] d, sz at, bool little) @local
{
	return little ? d[at] | d[at + 1] << 8 : d[at] << 8 | d[at + 1];
}

fn int exif_orientation(char[] tiff) @local
{
	if (tiff.len < 8) return 1;
	bool little = tiff[0] == 'I';
	sz table = read_u16(tiff, little ? 4 : 6, little);
	if (table + 2 > tiff.len) return 1;
	int entries = read_u16(tiff, table, little);
	for (int i = 0; i < entries; i++)
	{
		sz entry = table + 2 + (sz)i * 12;
		if (entry + 12 > tiff.len) return 1;
		if (read_u16(tiff, entry, little) == 0x0112) return read_u16(tiff, entry + 8, little);
	}
	return 1;
}

<*
 The EXIF orientation of a JPEG (1 to 8), which is how phones record that a photo was
 taken sideways. Anything else reports 1, meaning "as stored".
*>
fn int jpeg_orientation(char[] d)
{
	if (d.len < 4 || d[0] != 0xFF || d[1] != 0xD8) return 1;
	sz at = 2;
	while (at + 4 <= d.len && d[at] == 0xFF)
	{
		char marker = d[at + 1];
		sz size = read_u16(d, at + 2, false);
		if (marker == 0xDA || size < 2 || at + 2 + size > d.len) return 1;
		if (marker == 0xE1 && size >= 10 && d[at + 4 : 6] == "Exif\0\0")
		{
			int orientation = exif_orientation(d[at + 10 : size - 8]);
			return orientation >= 1 && orientation <= 8 ? orientation : 1;
		}
		at += 2 + size;
	}
	return 1;
}
