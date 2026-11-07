// The floating toolbars and everything else drawn in screen space on top of the board.
module tabla::ui;
import tabla::app, tabla::board, tabla::geom, tabla::render, tabla::input, tabla::dialog;
import raylib55::rl;
import std::math, std::collections::list;

const float MIN_PEN_SIZE = 1;
const float MAX_PEN_SIZE = 160;

const Rgba PANEL = { 255, 255, 255, 250 };
const Rgba BORDER = { 20, 24, 32, 28 };
const Rgba INK = { 44, 48, 56, 255 };
const Rgba MUTED = { 112, 118, 128, 255 };
const Rgba ACCENT = { 59, 110, 246, 255 };
const Rgba ACCENT_SOFT = { 59, 110, 246, 34 };
const Rgba HOVER = { 20, 24, 32, 18 };
const Rgba WHITE = { 255, 255, 255, 255 };
const Rgba DARK = { 28, 31, 38, 240 };

const Rgba[12] INK_COLORS = {
	{ 26, 26, 30, 255 },
	{ 107, 114, 128, 255 },
	{ 255, 255, 255, 255 },
	{ 229, 56, 59, 255 },
	{ 247, 127, 0, 255 },
	{ 252, 214, 40, 255 },
	{ 87, 204, 153, 255 },
	{ 42, 157, 143, 255 },
	{ 76, 201, 240, 255 },
	{ 29, 111, 224, 255 },
	{ 123, 44, 191, 255 },
	{ 241, 91, 181, 255 },
};

const Rgba[7] NOTE_COLORS = {
	{ 255, 240, 150, 255 },
	{ 255, 214, 165, 255 },
	{ 255, 183, 183, 255 },
	{ 202, 240, 191, 255 },
	{ 175, 230, 245, 255 },
	{ 208, 200, 255, 255 },
	{ 245, 245, 245, 255 },
};

enum Icon : char
{
	SELECT,
	HAND,
	PEN,
	BRUSH,
	MARKER,
	HIGHLIGHTER,
	ERASER,
	LINE,
	ARROW,
	RECT,
	ELLIPSE,
	TEXT,
	NOTE,
	IMAGE,
	UNDO,
	REDO,
	MINUS,
	PLUS,
	FIT,
	PAPER,
	EXPORT,
	OPEN,
	SAVE,
	HELP,
	FRONT,
	BACK,
	DUPLICATE,
	TRASH,
}

struct RailEntry
{
	Tool tool;
	Icon icon;
	ZString tip;
	bool gap_before;
}

const RailEntry[*] RAIL = {
	{ SELECT, SELECT, "Select and move  (V)", false },
	{ HAND, HAND, "Pan  (H, or hold Space)", false },
	{ PEN, PEN, "Pen  (P)", true },
	{ BRUSH, BRUSH, "Brush: thins out with speed  (B)", false },
	{ MARKER, MARKER, "Marker: chisel tip  (M)", false },
	{ HIGHLIGHTER, HIGHLIGHTER, "Highlighter  (Y)", false },
	{ ERASER, ERASER, "Eraser: hold Shift for whole strokes  (E)", false },
	{ LINE, LINE, "Line: Shift snaps the angle  (L)", true },
	{ ARROW, ARROW, "Arrow  (A)", false },
	{ RECT, RECT, "Rectangle: Shift makes a square  (R)", false },
	{ ELLIPSE, ELLIPSE, "Ellipse: Shift makes a circle  (O)", false },
	{ TEXT, TEXT, "Text  (T)", true },
	{ NOTE, NOTE, "Sticky note  (N)", false },
};

struct HelpLine
{
	String keys;
	String what;
}

const HelpLine[*] HELP_LEFT = {
	{ "V  H", "Select, pan" },
	{ "P  B  M  Y", "Pen, brush, marker, highlighter" },
	{ "E", "Eraser (Shift: whole strokes)" },
	{ "L  A  R  O", "Line, arrow, rectangle, ellipse" },
	{ "T  N", "Text, sticky note" },
	{ "I", "Add pictures" },
	{ "[  ]", "Pen size, or layer order when selecting" },
	{ "Shift", "Straight angles, squares, circles" },
	{ "Esc", "Back to Select" },
};

const HelpLine[*] HELP_RIGHT = {
	{ "Wheel", "Zoom" },
	{ "Space, middle or right drag", "Pan" },
	{ "Home, Ctrl+1", "Fit everything" },
	{ "Ctrl+0", "Zoom to 100%" },
	{ "Ctrl+Z, Ctrl+Y", "Undo, redo" },
	{ "Ctrl+C  X  V  D", "Copy, cut, paste, duplicate" },
	{ "Ctrl+A, Delete", "Select all, delete" },
	{ "Ctrl+S, Ctrl+Shift+S", "Save, save as" },
	{ "Ctrl+O, Ctrl+N", "Open, new board" },
	{ "Ctrl+E", "Export PNG" },
};

const int SLIDER_SIZE = 1;
const int SLIDER_OPACITY = 2;
const int SLIDER_SMOOTHING = 3;
const int SLIDER_SV = 4;
const int SLIDER_HUE = 5;

const float BUTTON = 36;
const float SLIDER_WIDTH = 92;
const float SLIDER_BLOCK = 128;
const float SWATCH = 26;

struct Ui
{
	RLRectangle rail;
	RLRectangle top;
	RLRectangle bar;
	RLRectangle title;
	RLRectangle picker;
	RLRectangle paper_menu;
	RLRectangle help;
	bool bar_visible;
	bool picker_open;
	bool paper_open;
	int active;
	bool recoloring;
	bool enabled;
	float hue;
	float saturation;
	float value;
	ZString tip;
	Vec2 tip_at;
	Rgba last_custom;
}

fn bool inside(RLRectangle r, Vec2 p) @local
{
	return p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height;
}

fn Vec2 at(Vec2 c, float x, float y) @local => { c.x + x, c.y + y };

fn float rail_height() @local
{
	float height = (BUTTON + 2) * (RAIL.len + 1) + 12;
	foreach (entry : RAIL)
	{
		if (entry.gap_before) height += 11;
	}
	return height + 11;
}

fn float bar_width(App* a) @local
{
	Tool tool = a.tool;
	float width = 24;
	if (tool == SELECT)
	{
		if (a.selection.is_empty()) return 0;
		return width + 4 * BUTTON + 14 + INK_COLORS.len * SWATCH + SWATCH + 8;
	}
	if (tool == HAND) return 0;
	if (tool == ERASER) return width + SLIDER_BLOCK;
	if (tool == NOTE) return width + NOTE_COLORS.len * SWATCH;
	width += INK_COLORS.len * SWATCH + SWATCH + 14 + SLIDER_BLOCK;
	if (tool == TEXT) return width;
	width += SLIDER_BLOCK;
	if (tool.is_ink()) width += SLIDER_BLOCK;
	return width;
}

fn void Ui.layout(&self, App* a, Input* in)
{
	float w = in.width;
	float h = in.height;
	float rail_h = rail_height();
	self.rail = { .x = 12, .y = math::max(12.0f, (h - rail_h) * 0.5f), .width = BUTTON + 10, .height = rail_h };
	float top_w = BUTTON * 10 + 54 + 24;
	self.top = { .x = w - top_w - 12, .y = 12, .width = top_w, .height = BUTTON + 10 };
	float bar_w = bar_width(a);
	self.bar_visible = bar_w > 0;
	self.bar = { .x = (w - bar_w) * 0.5f, .y = h - 64, .width = bar_w, .height = 52 };
	self.picker = { .x = self.bar.x + 24, .y = self.bar.y - 196, .width = 212, .height = 188 };
	self.paper_menu = { .x = w - 12 - 200, .y = self.top.y + self.top.height + 8, .width = 200, .height = 112 };
	self.help = { .x = (w - 860) * 0.5f, .y = (h - 372) * 0.5f, .width = 860, .height = 372 };
	if (!self.bar_visible) self.picker_open = false;
}

<*
 Whether the pointer is over any part of the interface, in which case the board must
 not react to it. A drag that started on the board carries on regardless.
*>
fn bool Ui.covers(&self, App* a, Input* in)
{
	if (a.help_open || self.active) return true;
	if (a.mode != IDLE) return false;
	Vec2 m = in.mouse;
	if (inside(self.rail, m) || inside(self.top, m) || inside(self.title, m)) return true;
	if (self.bar_visible && inside(self.bar, m)) return true;
	if (self.picker_open && inside(self.picker, m)) return true;
	if (self.paper_open && inside(self.paper_menu, m)) return true;
	return false;
}

fn void panel(RLRectangle r, float radius = 12) @local
{
	float roundness = radius * 2 / math::min(r.width, r.height);
	for (int i = 3; i > 0; i--)
	{
		float grow = i * 2.0f;
		RLRectangle shadow = { .x = r.x - grow, .y = r.y - grow + 3, .width = r.width + grow * 2, .height = r.height + grow * 2 };
		float shadow_round = (radius + grow) * 2 / math::min(shadow.width, shadow.height);
		rl::draw_rectangle_rounded(shadow, shadow_round, 8, { 10, 14, 24, 7 });
	}
	rl::draw_rectangle_rounded(r, roundness, 8, PANEL);
	rl::draw_rectangle_rounded_lines_ex(r, roundness, 8, 1, BORDER);
}

fn void label(RLFont font, String text, float x, float y, Rgba color) @local
{
	@pool()
	{
		rl::draw_text_ex(font, text.zstr_tcopy(), { math::floor(x), math::floor(y) }, font.base_size, 0, color);
	};
}

fn float text_width(RLFont font, String text) @local
{
	@pool()
	{
		return rl::measure_text_ex(font, text.zstr_tcopy(), font.base_size, 0).x;
	};
}

fn void stroke(Vec2 c, float x0, float y0, float x1, float y1, Rgba color, float width = 1.8f) @local
{
	rl::draw_line_ex(at(c, x0, y0), at(c, x1, y1), width, color);
	if (width >= 1.6f)
	{
		rl::draw_circle_v(at(c, x0, y0), width * 0.5f, color);
		rl::draw_circle_v(at(c, x1, y1), width * 0.5f, color);
	}
}

fn void box(Vec2 c, float x0, float y0, float x1, float y1, Rgba color, float width = 1.8f) @local
{
	stroke(c, x0, y0, x1, y0, color, width);
	stroke(c, x1, y0, x1, y1, color, width);
	stroke(c, x1, y1, x0, y1, color, width);
	stroke(c, x0, y1, x0, y0, color, width);
}

fn void ring(Vec2 c, float x, float y, float r, Rgba color, float width = 1.8f, float from = 0, float to = 360) @local
{
	rl::draw_ring(at(c, x, y), r - width * 0.5f, r + width * 0.5f, from, to, 32, color);
}

fn void draw_icon(Icon icon, Vec2 c, Rgba color) @local
{
	switch (icon)
	{
		case SELECT:
			float[14] p = { -4, -8, -4, 6, 0, 2.5f, 2.5f, 8, 5, 7, 2.5f, 1.5f, 7, 1.5f };
			for (int i = 0; i < 7; i++)
			{
				int j = (i + 1) % 7;
				stroke(c, p[i * 2], p[i * 2 + 1], p[j * 2], p[j * 2 + 1], color, 1.7f);
			}
		case HAND:
			stroke(c, 0, -8, 0, 8, color);
			stroke(c, -8, 0, 8, 0, color);
			stroke(c, -2.5f, -5.5f, 0, -8, color);
			stroke(c, 2.5f, -5.5f, 0, -8, color);
			stroke(c, -2.5f, 5.5f, 0, 8, color);
			stroke(c, 2.5f, 5.5f, 0, 8, color);
			stroke(c, -5.5f, -2.5f, -8, 0, color);
			stroke(c, -5.5f, 2.5f, -8, 0, color);
			stroke(c, 5.5f, -2.5f, 8, 0, color);
			stroke(c, 5.5f, 2.5f, 8, 0, color);
		case PEN:
			stroke(c, -4, 4, 6, -6, color, 3.2f);
			stroke(c, -8, 8, -4, 4, color, 1.4f);
		case BRUSH:
			stroke(c, 1, -1, 7, -7, color, 2.4f);
			rl::draw_circle_v(at(c, -3, 3), 3.6f, color);
			stroke(c, -3, 3, -8, 8, color, 2.2f);
		case MARKER:
			stroke(c, -2, 2, 5, -5, color, 6.5f);
			stroke(c, -7.5f, 7.5f, -4, 4, color, 3.2f);
		case HIGHLIGHTER:
			rl::draw_rectangle_rec({ .x = c.x - 9, .y = c.y + 0.5f, .width = 18, .height = 7 }, { 252, 214, 40, 255 });
			stroke(c, -7, -5, 7, -5, color);
			stroke(c, -7, 4, 4, 4, color);
		case ERASER:
			stroke(c, -1, 1, 5, -5, color, 8);
			stroke(c, -5, 5, -2, 2, { color.r, color.g, color.b, 110 }, 8);
			stroke(c, -9, 9, 9, 9, color, 1.4f);
		case LINE:
			stroke(c, -7, 7, 7, -7, color);
			rl::draw_circle_v(at(c, -7, 7), 2.4f, color);
			rl::draw_circle_v(at(c, 7, -7), 2.4f, color);
		case ARROW:
			stroke(c, -7, 7, 7, -7, color);
			stroke(c, 7, -7, 0, -7, color);
			stroke(c, 7, -7, 7, 0, color);
		case RECT:
			box(c, -8, -6, 8, 6, color);
		case ELLIPSE:
			ring(c, 0, 0, 8, color);
		case TEXT:
			stroke(c, -7, -7, 7, -7, color, 2.2f);
			stroke(c, 0, -7, 0, 8, color, 2.2f);
		case NOTE:
			stroke(c, -8, -8, 8, -8, color);
			stroke(c, -8, -8, -8, 8, color);
			stroke(c, 8, -8, 8, 2, color);
			stroke(c, -8, 8, 2, 8, color);
			stroke(c, 2, 8, 8, 2, color);
			stroke(c, 2, 8, 2, 2, color, 1.4f);
			stroke(c, 2, 2, 8, 2, color, 1.4f);
		case IMAGE:
			box(c, -9, -7, 9, 7, color);
			rl::draw_circle_v(at(c, 3.5f, -2.5f), 1.9f, color);
			stroke(c, -9, 6, -3, -1, color);
			stroke(c, -3, -1, 2, 4, color);
			stroke(c, 2, 4, 4.5f, 2, color);
			stroke(c, 4.5f, 2, 9, 6, color);
		case UNDO:
			ring(c, 0.5f, 1, 7, color, 1.8f, 180, 405);
			stroke(c, -6.5f, 1, -9.5f, -3, color);
			stroke(c, -6.5f, 1, -2.5f, -2.5f, color);
		case REDO:
			ring(c, -0.5f, 1, 7, color, 1.8f, 135, 360);
			stroke(c, 6.5f, 1, 9.5f, -3, color);
			stroke(c, 6.5f, 1, 2.5f, -2.5f, color);
		case MINUS:
			stroke(c, -6, 0, 6, 0, color, 2);
		case PLUS:
			stroke(c, -6, 0, 6, 0, color, 2);
			stroke(c, 0, -6, 0, 6, color, 2);
		case FIT:
			foreach (int[<2>] d : (int[<2>][]){ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } })
			{
				Vec2 v = { (float)d.x, (float)d.y };
				stroke(c, v.x * 8, v.y * 8, v.x * 3.5f, v.y * 8, color);
				stroke(c, v.x * 8, v.y * 8, v.x * 8, v.y * 3.5f, color);
			}
		case PAPER:
			box(c, -8, -8, 8, 8, color);
			for (int x = -1; x <= 1; x++)
			{
				for (int y = -1; y <= 1; y++) rl::draw_circle_v(at(c, x * 4.0f, y * 4.0f), 1.15f, color);
			}
		case EXPORT:
			stroke(c, 0, 4, 0, -8, color);
			stroke(c, 0, -8, -4, -4, color);
			stroke(c, 0, -8, 4, -4, color);
			stroke(c, -8, 2, -8, 8, color);
			stroke(c, -8, 8, 8, 8, color);
			stroke(c, 8, 8, 8, 2, color);
		case OPEN:
			stroke(c, -9, 7, -9, -6, color);
			stroke(c, -9, -6, -3, -6, color);
			stroke(c, -3, -6, -1, -3, color);
			stroke(c, -1, -3, 9, -3, color);
			stroke(c, 9, -3, 9, 7, color);
			stroke(c, 9, 7, -9, 7, color);
		case SAVE:
			box(c, -8, -8, 8, 8, color);
			stroke(c, -4, -8, -4, -3, color, 1.5f);
			stroke(c, -4, -3, 4, -3, color, 1.5f);
			stroke(c, 4, -3, 4, -8, color, 1.5f);
			box(c, -4, 2, 4, 8, color, 1.5f);
		case HELP:
			ring(c, 0, -3, 4.5f, color, 2, 165, 405);
			stroke(c, 0, 1.5f, 0, 3.5f, color, 2);
			rl::draw_circle_v(at(c, 0, 8), 1.4f, color);
		case FRONT:
			box(c, -3, -8, 8, 3, color);
			stroke(c, -3, 3, -8, 3, { color.r, color.g, color.b, 120 });
			stroke(c, -8, 3, -8, 8, { color.r, color.g, color.b, 120 });
			stroke(c, -8, 8, 3, 8, { color.r, color.g, color.b, 120 });
			stroke(c, 3, 8, 3, 3, { color.r, color.g, color.b, 120 });
		case BACK:
			box(c, -8, -3, 3, 8, color);
			stroke(c, -3, -3, -3, -8, { color.r, color.g, color.b, 120 });
			stroke(c, -3, -8, 8, -8, { color.r, color.g, color.b, 120 });
			stroke(c, 8, -8, 8, 3, { color.r, color.g, color.b, 120 });
			stroke(c, 8, 3, 3, 3, { color.r, color.g, color.b, 120 });
		case DUPLICATE:
			box(c, -8, -8, 3, 3, color);
			box(c, -3, -3, 8, 8, color);
		case TRASH:
			stroke(c, -8, -5, 8, -5, color);
			stroke(c, -3, -5, -2, -8, color);
			stroke(c, -2, -8, 2, -8, color);
			stroke(c, 2, -8, 3, -5, color);
			stroke(c, -6, -5, -5, 8, color);
			stroke(c, -5, 8, 5, 8, color);
			stroke(c, 5, 8, 6, -5, color);
			stroke(c, -2, -1, -2, 4, color, 1.4f);
			stroke(c, 2, -1, 2, 4, color, 1.4f);
	}
}

fn bool Ui.button(&self, Input* in, RLRectangle r, Icon icon, ZString tip, bool active = false, bool enabled = true)
{
	bool hover = self.enabled && inside(r, in.mouse);
	float roundness = 0.28f;
	if (active)
	{
		rl::draw_rectangle_rounded(r, roundness, 6, ACCENT);
	}
	else if (hover && enabled)
	{
		rl::draw_rectangle_rounded(r, roundness, 6, HOVER);
	}
	Rgba color = active ? WHITE : enabled ? INK : (Rgba){ 44, 48, 56, 80 };
	draw_icon(icon, { r.x + r.width * 0.5f, r.y + r.height * 0.5f }, color);
	if (hover)
	{
		self.tip = tip;
		self.tip_at = { r.x + r.width + 10, r.y + r.height * 0.5f };
	}
	return hover && enabled && in.left_pressed;
}

fn bool Ui.swatch(&self, Input* in, Vec2 c, Rgba color, bool chosen)
{
	float r = 9;
	bool hover = self.enabled && geom::length(in.mouse - c) <= r + 3;
	if (hover) r = 10;
	if (chosen) rl::draw_ring(c, r + 2.2f, r + 3.6f, 0, 360, 32, ACCENT);
	rl::draw_circle_v(c, r, color);
	rl::draw_ring(c, r - 0.75f, r + 0.25f, 0, 360, 32, { 0, 0, 0, 36 });
	return hover && in.left_pressed;
}

fn bool Ui.slider(&self, Input* in, int id, float x, float y, String name, String value, float* t)
{
	RLRectangle track = { .x = x, .y = y + 27, .width = SLIDER_WIDTH, .height = 4 };
	RLRectangle reach = { .x = x - 6, .y = y, .width = SLIDER_WIDTH + 12, .height = 42 };
	if (self.enabled && inside(reach, in.mouse) && in.left_pressed) self.active = id;
	bool changed = false;
	if (self.active == id)
	{
		*t = math::clamp((in.mouse.x - x) / SLIDER_WIDTH, 0.0f, 1.0f);
		changed = true;
		if (!in.left_down) self.active = 0;
	}
	rl::draw_rectangle_rounded(track, 1, 4, { 20, 24, 32, 30 });
	RLRectangle filled = track;
	filled.width = track.width * *t;
	rl::draw_rectangle_rounded(filled, 1, 4, ACCENT);
	Vec2 knob = { x + SLIDER_WIDTH * *t, y + 29 };
	rl::draw_circle_v(knob, 7, WHITE);
	rl::draw_ring(knob, 6.25f, 7.25f, 0, 360, 24, { 20, 24, 32, 70 });
	return changed;
}

fn void Ui.pick_color(&self, App* a, Rgba color, bool commit)
{
	if (a.tool == SELECT)
	{
		a.recolor_selection(color, commit);
		if (!commit) self.recoloring = true;
		return;
	}
	color.a = 255;
	a.styles[a.tool.ordinal].color = color;
}

fn float size_to_slider(float size) @local
{
	return math::sqrt((size - MIN_PEN_SIZE) / (MAX_PEN_SIZE - MIN_PEN_SIZE));
}

fn float slider_to_size(float t) @local
{
	return MIN_PEN_SIZE + t * t * (MAX_PEN_SIZE - MIN_PEN_SIZE);
}

fn Rgba hsv(float h, float s, float v) @local
{
	float c = v * s;
	float sector = h * 6;
	float x = c * (1 - math::abs(sector % 2 - 1));
	float[<3>] rgb;
	switch ((int)sector)
	{
		case 0: rgb = { c, x, 0 };
		case 1: rgb = { x, c, 0 };
		case 2: rgb = { 0, c, x };
		case 3: rgb = { 0, x, c };
		case 4: rgb = { x, 0, c };
		default: rgb = { c, 0, x };
	}
	rgb += v - c;
	return { (char)(rgb.x * 255), (char)(rgb.y * 255), (char)(rgb.z * 255), 255 };
}

fn void Ui.load_picker(&self, Rgba color)
{
	float r = color.r / 255.0f;
	float g = color.g / 255.0f;
	float b = color.b / 255.0f;
	float high = math::max(r, g, b);
	float low = math::min(r, g, b);
	float d = high - low;
	self.value = high;
	self.saturation = high > 0 ? d / high : 0;
	if (d <= 0) return; // grey has no hue: keep the one the picker shows
	float h = high == r ? ((g - b) / d) % 6 : high == g ? (b - r) / d + 2 : (r - g) / d + 4;
	self.hue = (h < 0 ? h + 6 : h) / 6;
}

fn void Ui.draw_picker(&self, App* a, Input* in)
{
	RLRectangle p = self.picker;
	panel(p);
	RLRectangle field = { .x = p.x + 12, .y = p.y + 12, .width = p.width - 24, .height = 132 };
	RLRectangle strip = { .x = field.x, .y = field.y + field.height + 12, .width = field.width, .height = 16 };
	bool can_grab = self.enabled && in.left_pressed;
	if (can_grab && inside(field, in.mouse)) self.active = SLIDER_SV;
	if (can_grab && inside(strip, in.mouse)) self.active = SLIDER_HUE;
	bool changed = false;
	if (self.active == SLIDER_SV)
	{
		self.saturation = math::clamp((in.mouse.x - field.x) / field.width, 0.0f, 1.0f);
		self.value = 1 - math::clamp((in.mouse.y - field.y) / field.height, 0.0f, 1.0f);
		changed = true;
	}
	else if (self.active == SLIDER_HUE)
	{
		self.hue = math::clamp((in.mouse.x - strip.x) / strip.width, 0.0f, 0.999f);
		changed = true;
	}
	Rgba pure = hsv(self.hue, 1, 1);
	// raylib walks the corners round the rectangle: top left, bottom left, bottom right,
	// top right. Its last two parameter names have those the other way round.
	rl::draw_rectangle_gradient_ex(field, WHITE, WHITE, pure, pure);
	rl::draw_rectangle_gradient_ex(field, { 0, 0, 0, 0 }, { 0, 0, 0, 255 }, { 0, 0, 0, 255 }, { 0, 0, 0, 0 });
	Vec2 mark = { field.x + field.width * self.saturation, field.y + field.height * (1 - self.value) };
	rl::draw_ring(mark, 5, 7, 0, 360, 20, WHITE);
	rl::draw_ring(mark, 4, 5, 0, 360, 20, { 0, 0, 0, 120 });
	float part = strip.width / 6;
	for (int i = 0; i < 6; i++)
	{
		Rgba from = hsv((float)i / 6.0f, 1, 1);
		Rgba to = hsv(math::min((float)(i + 1) / 6.0f, 0.999f), 1, 1);
		rl::draw_rectangle_gradient_ex({ .x = strip.x + i * part, .y = strip.y, .width = part + 0.5f, .height = strip.height }, from, from, to, to);
	}
	rl::draw_rectangle_rec({ .x = strip.x + strip.width * self.hue - 1.5f, .y = strip.y - 2, .width = 3, .height = strip.height + 4 }, WHITE);
	if (changed)
	{
		Rgba color = hsv(self.hue, self.saturation, self.value);
		self.last_custom = color;
		self.pick_color(a, color, false);
	}
	if (self.active && !in.left_down && (self.active == SLIDER_SV || self.active == SLIDER_HUE)) self.active = 0;
}

fn void Ui.draw_bar(&self, App* a, Input* in)
{
	if (!self.bar_visible) return;
	panel(self.bar);
	Tool tool = a.tool;
	float x = self.bar.x + 12;
	float y = self.bar.y;
	float cy = y + self.bar.height * 0.5f;
	PenStyle* style = &a.styles[tool.ordinal];

	if (tool == SELECT)
	{
		RLRectangle r = { .x = x, .y = y + 8, .width = BUTTON, .height = BUTTON };
		if (self.button(in, r, FRONT, "Bring to front  ( ] )")) a.bring_to_front();
		r.x += BUTTON;
		if (self.button(in, r, BACK, "Send to back  ( [ )")) a.send_to_back();
		r.x += BUTTON;
		if (self.button(in, r, DUPLICATE, "Duplicate  (Ctrl+D)")) a.duplicate();
		r.x += BUTTON;
		if (self.button(in, r, TRASH, "Delete  (Del)")) a.delete_selection();
		x = r.x + BUTTON + 14;
	}

	if (tool == NOTE)
	{
		foreach (color : NOTE_COLORS)
		{
			if (self.swatch(in, { x + SWATCH * 0.5f, cy }, color, color == style.color)) style.color = color;
			x += SWATCH;
		}
		return;
	}

	if (tool != ERASER)
	{
		foreach (color : INK_COLORS)
		{
			bool chosen = tool != SELECT && color.xyz == style.color.xyz;
			if (self.swatch(in, { x + SWATCH * 0.5f, cy }, color, chosen)) self.pick_color(a, color, true);
			x += SWATCH;
		}
		Vec2 c = { x + SWATCH * 0.5f, cy };
		bool hover = self.enabled && geom::length(in.mouse - c) <= 12;
		for (int i = 0; i < 12; i++)
		{
			float from = i * 30.0f;
			rl::draw_ring(c, hover ? 6.5f : 5.5f, 10, from, from + 31, 4, hsv(i / 12.0f, 0.85f, 0.95f));
		}
		if (self.picker_open) rl::draw_ring(c, 12, 13.4f, 0, 360, 32, ACCENT);
		if (hover)
		{
			self.tip = "Pick any colour";
			self.tip_at = { c.x - 40, y - 16 };
			if (in.left_pressed)
			{
				self.picker_open = !self.picker_open;
				self.paper_open = false;
				if (self.picker_open) self.load_picker(tool == SELECT ? self.last_custom : style.color);
			}
		}
		x += SWATCH + 14;
	}
	if (tool == SELECT) return;

	@pool()
	{
		float t = size_to_slider(style.size);
		String size_text = string::tformat("%d px", (int)math::round(style.size));
		label(a.gfx.ui_font, tool == TEXT ? "Text size" : "Size", x, y + 8, MUTED);
		label(a.gfx.ui_font, size_text, x + SLIDER_WIDTH - text_width(a.gfx.ui_font, size_text), y + 8, INK);
		if (self.slider(in, SLIDER_SIZE, x, y + 2, "Size", size_text, &t)) style.size = slider_to_size(t);
		x += SLIDER_BLOCK;

		if (tool == ERASER || tool == TEXT) return;

		String percent = string::tformat("%d%%", (int)math::round(style.opacity * 100));
		label(a.gfx.ui_font, "Opacity", x, y + 8, MUTED);
		label(a.gfx.ui_font, percent, x + SLIDER_WIDTH - text_width(a.gfx.ui_font, percent), y + 8, INK);
		t = (style.opacity - 0.05f) / 0.95f;
		if (self.slider(in, SLIDER_OPACITY, x, y + 2, "Opacity", percent, &t)) style.opacity = 0.05f + t * 0.95f;
		x += SLIDER_BLOCK;

		if (!tool.is_ink()) return;

		String smooth_text = string::tformat("%d%%", (int)math::round(style.smoothing * 100));
		label(a.gfx.ui_font, "Smoothing", x, y + 8, MUTED);
		label(a.gfx.ui_font, smooth_text, x + SLIDER_WIDTH - text_width(a.gfx.ui_font, smooth_text), y + 8, INK);
		t = style.smoothing;
		if (self.slider(in, SLIDER_SMOOTHING, x, y + 2, "Smoothing", smooth_text, &t)) style.smoothing = t;
	};
}

fn void Ui.draw_rail(&self, App* a, Input* in)
{
	panel(self.rail);
	RLRectangle r = { .x = self.rail.x + 5, .y = self.rail.y + 6, .width = BUTTON, .height = BUTTON };
	foreach (entry : RAIL)
	{
		if (entry.gap_before)
		{
			rl::draw_rectangle_rec({ .x = r.x + 7, .y = r.y + 4, .width = BUTTON - 14, .height = 1 }, BORDER);
			r.y += 11;
		}
		if (self.button(in, r, entry.icon, entry.tip, a.tool == entry.tool))
		{
			a.set_tool(entry.tool);
			self.picker_open = false;
		}
		r.y += BUTTON + 2;
	}
	rl::draw_rectangle_rec({ .x = r.x + 7, .y = r.y + 4, .width = BUTTON - 14, .height = 1 }, BORDER);
	r.y += 11;
	if (self.button(in, r, IMAGE, "Add pictures, or drop or paste them  (I)")) a.request_dialog(ADD_IMAGES);
}

fn void Ui.draw_top(&self, App* a, Input* in)
{
	panel(self.top);
	RLRectangle r = { .x = self.top.x + 6, .y = self.top.y + 5, .width = BUTTON, .height = BUTTON };
	bool can_undo = a.board.undo_steps.len() > 0;
	bool can_redo = a.board.redo_steps.len() > 0;
	if (self.button(in, r, UNDO, "Undo  (Ctrl+Z)", enabled: can_undo)) a.undo();
	r.x += BUTTON;
	if (self.button(in, r, REDO, "Redo  (Ctrl+Y)", enabled: can_redo)) a.redo();
	r.x += BUTTON + 6;
	if (self.button(in, r, MINUS, "Zoom out  (-)")) a.zoom_at(a.view_center(), 1 / 1.4);
	r.x += BUTTON;

	RLRectangle zoom = { .x = r.x, .y = r.y, .width = 54, .height = BUTTON };
	bool hover = self.enabled && inside(zoom, in.mouse);
	if (hover)
	{
		rl::draw_rectangle_rounded(zoom, 0.28f, 6, HOVER);
		self.tip = "Back to 100%  (Ctrl+0)";
		self.tip_at = { zoom.x + 10, zoom.y + zoom.height + 16 };
		if (in.left_pressed) a.zoom_at(a.view_center(), 1 / a.cam_target.zoom);
	}
	@pool()
	{
		double percent = a.cam_target.zoom * 100;
		String text = percent >= 10 ? string::tformat("%d%%", (long)math::round(percent)) : string::tformat("%.2g%%", percent);
		label(a.gfx.ui_font, text, zoom.x + (zoom.width - text_width(a.gfx.ui_font, text)) * 0.5f, zoom.y + 11, INK);
	};
	r.x += zoom.width;

	if (self.button(in, r, PLUS, "Zoom in  (+)")) a.zoom_at(a.view_center(), 1.4);
	r.x += BUTTON;
	if (self.button(in, r, FIT, "Fit everything  (Home)")) a.fit_all();
	r.x += BUTTON + 6;
	if (self.button(in, r, PAPER, "Paper style", self.paper_open))
	{
		self.paper_open = !self.paper_open;
		self.picker_open = false;
	}
	r.x += BUTTON;
	if (self.button(in, r, EXPORT, "Export PNG  (Ctrl+E)")) a.request_dialog(EXPORT_PNG);
	r.x += BUTTON;
	if (self.button(in, r, OPEN, "Open board  (Ctrl+O)")) a.request_dialog(OPEN_BOARD);
	r.x += BUTTON;
	if (self.button(in, r, HELP, "Shortcuts  (F1)")) a.help_open = true;
}

fn void Ui.draw_paper_menu(&self, App* a, Input* in)
{
	if (!self.paper_open) return;
	RLRectangle p = self.paper_menu;
	panel(p);
	label(a.gfx.ui_font, "Paper", p.x + 14, p.y + 11, MUTED);
	float x = p.x + 28;
	foreach (i, paper : render::PAPERS)
	{
		if (self.swatch(in, { x, p.y + 46 }, paper.color, a.paper == (char)i))
		{
			a.paper = (char)i;
			a.view_dirty = true;
		}
		x += 34;
	}
	const String[*] NAMES = { "Dots", "Grid", "Plain" };
	x = p.x + 12;
	foreach (i, name : NAMES)
	{
		RLRectangle r = { .x = x, .y = p.y + 72, .width = 56, .height = 28 };
		bool hover = self.enabled && inside(r, in.mouse);
		bool chosen = a.pattern == (char)i;
		if (chosen)
		{
			rl::draw_rectangle_rounded(r, 0.3f, 6, ACCENT_SOFT);
		}
		else if (hover)
		{
			rl::draw_rectangle_rounded(r, 0.3f, 6, HOVER);
		}
		label(a.gfx.ui_font, name, r.x + (r.width - text_width(a.gfx.ui_font, name)) * 0.5f, r.y + 6, chosen ? ACCENT : INK);
		if (hover && in.left_pressed)
		{
			a.pattern = (char)i;
			a.view_dirty = true;
		}
		x += 60;
	}
}

fn void Ui.draw_title(&self, App* a, Input* in)
{
	@pool()
	{
		String name = a.path.len ? a.path.file_tbasename() ?? "board" : "Unsaved board";
		if (name.ends_with(".tabla")) name = name[:name.len - 6];
		String status = !a.path.len ? "not saved" : a.has_unsaved() ? "saving..." : "saved";
		float name_w = text_width(a.gfx.ui_bold, name);
		float status_w = text_width(a.gfx.ui_font, status);
		self.title = { .x = 12, .y = 12, .width = name_w + status_w + 44, .height = 36 };
		panel(self.title, 10);
		label(a.gfx.ui_bold, name, self.title.x + 14, self.title.y + 10, INK);
		label(a.gfx.ui_font, status, self.title.x + 30 + name_w, self.title.y + 10, MUTED);
	};
}

fn void Ui.draw_selection(&self, App* a, Input* in)
{
	Camera* cam = &a.cam;
	if (a.hover_id && !a.is_selected(a.hover_id))
	{
		Item*? item = a.board.get(a.hover_id);
		if (try item)
		{
			DRect b = item.bounds();
			Vec2 lo = cam.to_screen(b.lo);
			Vec2 hi = cam.to_screen(b.hi);
			rl::draw_rectangle_lines_ex({ .x = lo.x - 2, .y = lo.y - 2, .width = hi.x - lo.x + 4, .height = hi.y - lo.y + 4 }, 1.5f, { 59, 110, 246, 130 });
		}
	}
	DRect? box = a.selection_bounds();
	if (catch box) return;
	Vec2 lo = cam.to_screen(box.lo);
	Vec2 hi = cam.to_screen(box.hi);
	rl::draw_rectangle_lines_ex({ .x = lo.x, .y = lo.y, .width = hi.x - lo.x, .height = hi.y - lo.y }, 1.5f, ACCENT);
	Vec2[4] corners = { lo, { hi.x, lo.y }, hi, { lo.x, hi.y } };
	foreach (c : corners)
	{
		rl::draw_rectangle_rec({ .x = c.x - 5, .y = c.y - 5, .width = 10, .height = 10 }, WHITE);
		rl::draw_rectangle_lines_ex({ .x = c.x - 5, .y = c.y - 5, .width = 10, .height = 10 }, 1.5f, ACCENT);
	}
}

fn void Ui.draw_marquee(&self, App* a, Input* in)
{
	if (a.mode != MARQUEE) return;
	Vec2 p = a.cam.to_screen(a.press_world);
	RLRectangle r = {
		.x = math::min(p.x, in.mouse.x), .y = math::min(p.y, in.mouse.y),
		.width = math::abs(in.mouse.x - p.x), .height = math::abs(in.mouse.y - p.y)
	};
	rl::draw_rectangle_rec(r, ACCENT_SOFT);
	rl::draw_rectangle_lines_ex(r, 1, ACCENT);
}

fn void Ui.draw_caret(&self, App* a, Input* in)
{
	if (!a.edit_id) return;
	Item*? item = a.board.get(a.edit_id);
	if (catch item) return;
	if ((in.time - a.caret_blink) % 1.0 > 0.6) return;
	bool note = item.fill.a > 0;
	float pad = note ? render::NOTE_PAD : 0;
	float wrap = note ? item.size.x - render::NOTE_PAD * 2 : 0;
	Vec2 local = a.gfx.caret_position(a.edit_string(), wrap, a.edit_caret);
	float s = (float)(item.scale * a.cam.zoom);
	Vec2 p = a.cam.to_screen(item.pos);
	rl::draw_rectangle_rec({
		.x = p.x + (pad + local.x) * s, .y = p.y + (pad + local.y) * s,
		.width = math::max(1.5f, 2 * s), .height = render::LINE_HEIGHT * s
	}, ACCENT);
}

fn void Ui.draw_pen_cursor(&self, App* a, Input* in)
{
	if (!a.cursor_hidden) return;
	PenStyle* style = &a.styles[a.tool.ordinal];
	float r = math::max(style.size * 0.5f, 1.5f);
	if (a.tool == ERASER)
	{
		rl::draw_circle_v(in.mouse, r, { 255, 255, 255, 120 });
		rl::draw_ring(in.mouse, r - 0.75f, r + 0.75f, 0, 360, 48, { 30, 30, 36, 200 });
		return;
	}
	Rgba tint = style.color;
	tint.a = 200;
	rl::draw_ring(in.mouse, r + 1, r + 2.2f, 0, 360, 48, { 255, 255, 255, 200 });
	rl::draw_ring(in.mouse, r, r + 1, 0, 360, 48, tint);
	if (r > 5) rl::draw_circle_v(in.mouse, 1.2f, tint);
}

fn void Ui.draw_tip(&self, App* a, Input* in)
{
	if (!self.tip) return;
	String text = self.tip.str_view();
	RLFont font = a.gfx.ui_font;
	float w = text_width(font, text) + 20;
	float x = math::min(self.tip_at.x, in.width - w - 8.0f);
	RLRectangle r = { .x = x, .y = self.tip_at.y - 13, .width = w, .height = 26 };
	rl::draw_rectangle_rounded(r, 0.35f, 6, DARK);
	label(font, text, r.x + 10, r.y + 5, WHITE);
}

fn void Ui.draw_toast(&self, App* a, Input* in)
{
	if (in.time >= a.toast_until) return;
	RLFont font = a.gfx.ui_font;
	float w = text_width(font, a.toast_text) + 32;
	RLRectangle r = { .x = (in.width - w) * 0.5f, .y = (float)(in.height - 112), .width = w, .height = 34 };
	rl::draw_rectangle_rounded(r, 0.4f, 8, DARK);
	label(font, a.toast_text, r.x + 16, r.y + 9, WHITE);
}

fn void Ui.draw_empty_hint(&self, App* a, Input* in)
{
	if (a.board.items.len() || a.mode != IDLE) return;
	Paper paper = render::PAPERS[a.paper % render::PAPERS.len];
	Rgba color = paper.mark;
	color.a = 170;
	String[*] lines = { "This board is empty and goes on forever.", "Draw, or drop and paste pictures here. Press F1 for shortcuts." };
	float y = in.height * 0.5f - 22;
	foreach (line : lines)
	{
		label(a.gfx.ui_font, line, (in.width - text_width(a.gfx.ui_font, line)) * 0.5f, y, color);
		y += 24;
	}
}

fn void draw_help_column(App* a, HelpLine[] lines, float x, float y, float keys_width) @local
{
	foreach (line : lines)
	{
		label(a.gfx.ui_bold, line.keys, x, y, INK);
		label(a.gfx.ui_font, line.what, x + keys_width, y, MUTED);
		y += 28;
	}
}

fn void Ui.draw_help(&self, App* a, Input* in)
{
	if (!a.help_open) return;
	rl::draw_rectangle(0, 0, in.width, in.height, { 10, 14, 24, 90 });
	RLRectangle h = self.help;
	panel(h, 16);
	rl::draw_rectangle_rounded(h, 32 / math::min(h.width, h.height), 8, WHITE);
	label(a.gfx.ui_bold, "Shortcuts", h.x + 28, h.y + 22, INK);
	draw_help_column(a, &HELP_LEFT, h.x + 28, h.y + 58, 104);
	draw_help_column(a, &HELP_RIGHT, h.x + 436, h.y + 58, 196);
	if (in.left_pressed) a.help_open = false;
}

fn void Ui.draw(&self, App* a, Input* in)
{
	self.tip = null;
	self.enabled = a.mode == IDLE && !a.help_open && !dialog::is_open();
	Tool tool_before = a.tool;

	self.draw_selection(a, in);
	self.draw_marquee(a, in);
	self.draw_caret(a, in);
	self.draw_empty_hint(a, in);
	self.draw_title(a, in);
	self.draw_rail(a, in);
	self.draw_top(a, in);
	self.draw_bar(a, in);
	if (self.picker_open) self.draw_picker(a, in);
	self.draw_paper_menu(a, in);
	self.draw_toast(a, in);
	self.draw_tip(a, in);
	self.draw_pen_cursor(a, in);
	self.draw_help(a, in);

	if (self.recoloring && !in.left_down)
	{
		self.recoloring = false;
		a.board.commit();
	}
	if (a.tool != tool_before) self.picker_open = false;
}
