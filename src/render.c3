// Everything that touches the GPU for the board itself: ink meshes, pictures, text and
// the paper. Items are placed through a double precision camera, and each item's mesh is
// in its own float space, so precision holds however far the view travels.
module tabla::render;
import tabla::geom, tabla::board, raylib55::rl;
import std::io, std::math, std::collections::list, std::core::string::conv;

const float TEXT_SIZE = 32;
const float LINE_HEIGHT = 40;
const float NOTE_PAD = 22;
const int SDF_SIZE = 48;
const int UI_FONT_SIZE = 14;
const int MAX_TEXTURE_SIZE = 4096;
const int LIVE_INITIAL_CAPACITY = 4096;
// How many new pictures may be decoded per frame while panning across a big board.
const int TEXTURES_PER_FRAME = 1;
const long TEXTURE_BUDGET = 2L * 1024 * 1024 * 1024;

const uint GL_FLOAT = 0x1406;
const uint GL_STENCIL_TEST = 0x0B90;
const uint GL_STENCIL_BUFFER_BIT = 0x400;
const uint GL_NOTEQUAL = 0x0205;
const uint GL_KEEP = 0x1E00;
const uint GL_REPLACE = 0x1E01;
const uint GL_FRAMEBUFFER = 0x8D40;
const uint GL_RENDERBUFFER = 0x8D41;
const uint GL_DEPTH24_STENCIL8 = 0x88F0;
const uint GL_DEPTH_STENCIL_ATTACHMENT = 0x821A;

alias GlCapabilityFn = fn void(uint cap);
alias GlClearFn = fn void(uint mask);
alias GlStencilFuncFn = fn void(uint func, int reference, uint mask);
alias GlStencilOpFn = fn void(uint fail, uint zfail, uint zpass);
alias GlGenFn = fn void(int count, uint* ids);
alias GlBindFn = fn void(uint target, uint id);
alias GlStorageFn = fn void(uint target, uint format, int width, int height);
alias GlAttachFn = fn void(uint target, uint attachment, uint kind, uint id);

// raylib's GL loader exports these pointers, so no extra linking is needed. rlgl itself
// has no stencil API.
extern GlCapabilityFn gl_enable @cname("glad_glEnable");
extern GlCapabilityFn gl_disable @cname("glad_glDisable");
extern GlClearFn gl_clear @cname("glad_glClear");
extern GlStencilFuncFn gl_stencil_func @cname("glad_glStencilFunc");
extern GlStencilOpFn gl_stencil_op @cname("glad_glStencilOp");
extern GlGenFn gl_gen_renderbuffers @cname("glad_glGenRenderbuffers");
extern GlGenFn gl_delete_renderbuffers @cname("glad_glDeleteRenderbuffers");
extern GlBindFn gl_bind_renderbuffer @cname("glad_glBindRenderbuffer");
extern GlBindFn gl_bind_framebuffer @cname("glad_glBindFramebuffer");
extern GlStorageFn gl_renderbuffer_storage @cname("glad_glRenderbufferStorage");
extern GlAttachFn gl_framebuffer_renderbuffer @cname("glad_glFramebufferRenderbuffer");
extern fn void flush_batch() @cname("rlDrawRenderBatchActive");

const String INK_VS = `#version 330
in vec2 vertexPosition;
uniform vec4 xform;
void main()
{
	gl_Position = vec4(vertexPosition * xform.zw + xform.xy, 0.0, 1.0);
}`;

const String INK_FS = `#version 330
uniform vec4 color;
out vec4 finalColor;
void main()
{
	finalColor = color;
}`;

const String SDF_FS = `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
out vec4 finalColor;
void main()
{
	float d = texture(texture0, fragTexCoord).a;
	float w = max(fwidth(d) * 0.75, 0.01);
	float a = smoothstep(0.5 - w, 0.5 + w, d);
	finalColor = vec4(fragColor.rgb, fragColor.a * a);
}`;

char[*] font_regular = $embed("../resources/fonts/DejaVuSans.ttf");
char[*] font_bold = $embed("../resources/fonts/DejaVuSans-Bold.ttf");

struct Camera
{
	DVec2 origin; // world position of the top-left screen corner
	double zoom;
}

fn Vec2 Camera.to_screen(&self, DVec2 p) => (Vec2)((p - self.origin) * self.zoom);
fn DVec2 Camera.to_world(&self, Vec2 p) => (DVec2)p / self.zoom + self.origin;

enum Pattern : char
{
	DOTS,
	GRID,
	PLAIN,
}

struct Paper
{
	Rgba color;
	Rgba mark;
}

const Paper[4] PAPERS = {
	{ { 250, 250, 248, 255 }, { 30, 30, 40, 60 } },
	{ { 247, 241, 227, 255 }, { 90, 70, 40, 70 } },
	{ { 32, 36, 42, 255 }, { 255, 255, 255, 46 } },
	{ { 24, 58, 50, 255 }, { 255, 255, 255, 40 } },
};

struct Line
{
	sz start;
	sz end;
	float width;
}

struct Renderer
{
	uint ink_shader;
	int loc_xform;
	int loc_color;
	RLShader sdf_shader;
	RLFont text_font;
	RLFont ui_font;
	RLFont ui_bold;

	ulong frame; // counts scenes, so that pictures can tell when they were last drawn
	long texture_budget;
	bool textures_waiting; // a visible picture has yet to load, so the app must not go idle

	uint live_vao;
	uint live_vbo;
	int live_capacity;

	List{Vec2} verts;
	List{InkPoint} flat;
	List{Line} lines;

	int width;
	int height;
	bool in_ink;
	bool stencil_on;
	int stencil_ref;
	int textures_left;
	bool load_all_textures;

	// Text being edited is shown live, before it becomes part of the document.
	uint edit_id;
	String edit_text;
}

fn CInt[] font_codepoints() @local
{
	List{CInt} set;
	set.tinit();
	for (int c = 32; c < 127; c++) set.push(c);
	for (int c = 160; c < 384; c++) set.push(c); // Latin-1 and Latin Extended-A
	for (int c = 0x400; c < 0x460; c++) set.push(c); // Cyrillic
	foreach (int c : (int[]){ 0x2013, 0x2014, 0x2018, 0x2019, 0x201A, 0x201C, 0x201D, 0x201E, 0x2022, 0x2026, 0x20AC, 0x2190, 0x2191, 0x2192, 0x2193, 0x2713 }) set.push(c);
	return set.array_view();
}

fn RLFont load_sdf_font(char[] ttf, CInt[] codepoints) @local
{
	RLFont font;
	font.base_size = SDF_SIZE;
	font.glyph_count = (int)codepoints.len;
	font.glyphs = rl::load_font_data(ttf.ptr, (int)ttf.len, SDF_SIZE, codepoints.ptr, (int)codepoints.len, RLFontType.SDF);
	RLImage atlas = rl::gen_image_font_atlas(font.glyphs, &font.recs, (int)codepoints.len, SDF_SIZE, 0, 1);
	font.texture = rl::load_texture_from_image(atlas);
	rl::unload_image(atlas);
	font.texture.set_filter(BILINEAR);
	return font;
}

fn void Renderer.init(&self)
{
	self.texture_budget = TEXTURE_BUDGET;
	self.verts.init(mem);
	self.flat.init(mem);
	self.lines.init(mem);
	self.ink_shader = rl::gl_load_shader_code(INK_VS.ptr, INK_FS.ptr);
	self.loc_xform = rl::gl_get_location_uniform(self.ink_shader, "xform");
	self.loc_color = rl::gl_get_location_uniform(self.ink_shader, "color");
	self.sdf_shader = rl::load_shader_from_memory(null, SDF_FS.zstr_tcopy());
	@pool()
	{
		CInt[] codepoints = font_codepoints();
		self.text_font = load_sdf_font(&font_regular, codepoints);
		self.ui_font = rl::load_font_from_memory(".ttf", &font_regular, font_regular.len, UI_FONT_SIZE, codepoints.ptr, (int)codepoints.len);
		self.ui_bold = rl::load_font_from_memory(".ttf", &font_bold, font_bold.len, UI_FONT_SIZE, codepoints.ptr, (int)codepoints.len);
	};
}

fn void Renderer.free(&self)
{
	rl::unload_font(self.text_font);
	rl::unload_font(self.ui_font);
	rl::unload_font(self.ui_bold);
	rl::unload_shader(self.sdf_shader);
	rl::gl_unload_shader_program(self.ink_shader);
	if (self.live_vao)
	{
		rl::gl_unload_vertex_array(self.live_vao);
		rl::gl_unload_vertex_buffer(self.live_vbo);
	}
	self.verts.free();
	self.flat.free();
	self.lines.free();
}

fn void Renderer.begin_scene(&self, int width, int height)
{
	self.width = width;
	self.height = height;
	self.stencil_ref = 0;
	self.frame++;
	self.textures_left = TEXTURES_PER_FRAME;
	self.textures_waiting = false;
	rl::gl_disable_backface_culling();
	flush_batch();
	gl_clear(GL_STENCIL_BUFFER_BIT);
}

fn void Renderer.begin_ink(&self) @inline
{
	if (self.in_ink) return;
	flush_batch();
	rl::gl_enable_shader(self.ink_shader);
	self.in_ink = true;
}

fn void Renderer.end_ink(&self)
{
	if (!self.in_ink) return;
	self.in_ink = false;
	if (self.stencil_on)
	{
		gl_disable(GL_STENCIL_TEST);
		self.stencil_on = false;
	}
	rl::gl_disable_vertex_array();
	rl::gl_disable_shader();
}

fn void Renderer.set_ink_state(&self, Camera* cam, DVec2 pos, double scale, Rgba color)
{
	double s = scale * cam.zoom;
	double sx = 2.0 / self.width;
	double sy = 2.0 / self.height;
	float[<4>] xform = {
		(float)((pos.x - cam.origin.x) * cam.zoom * sx - 1),
		(float)(1 - (pos.y - cam.origin.y) * cam.zoom * sy),
		(float)(s * sx),
		(float)(-s * sy)
	};
	float[<4>] rgba = { color.r / 255.0f, color.g / 255.0f, color.b / 255.0f, color.a / 255.0f };
	rl::gl_set_uniform(self.loc_xform, &xform, (CInt)RLShaderUniformDataType.VEC4.ordinal, 1);
	rl::gl_set_uniform(self.loc_color, &rgba, (CInt)RLShaderUniformDataType.VEC4.ordinal, 1);

	if (color.a == 255)
	{
		if (self.stencil_on)
		{
			gl_disable(GL_STENCIL_TEST);
			self.stencil_on = false;
		}
		return;
	}
	// Translucent ink may touch each pixel only once, or a stroke crossing itself would
	// show darker where it overlaps.
	if (!self.stencil_on)
	{
		gl_enable(GL_STENCIL_TEST);
		gl_stencil_op(GL_KEEP, GL_KEEP, GL_REPLACE);
		self.stencil_on = true;
	}
	if (++self.stencil_ref > 255)
	{
		gl_clear(GL_STENCIL_BUFFER_BIT);
		self.stencil_ref = 1;
	}
	gl_stencil_func(GL_NOTEQUAL, self.stencil_ref, 0xFF);
}

fn void Renderer.ensure_mesh(&self, Ink* ink)
{
	if (ink.vao) return;
	geom::tessellate(ink.points, ink.smooth, ink.tip, &self.verts, &self.flat);
	Vec2[] verts = self.verts.array_view();
	ink.vao = rl::gl_load_vertex_array();
	rl::gl_enable_vertex_array(ink.vao);
	ink.vbo = rl::gl_load_vertex_buffer(verts.ptr, (int)verts.len * Vec2::size, false);
	rl::gl_set_vertex_attribute(0, 2, GL_FLOAT, false, 0, 0);
	rl::gl_enable_vertex_attribute(0);
	rl::gl_disable_vertex_array();
	ink.vertex_count = (int)verts.len;
}

fn void Renderer.draw_ink(&self, Camera* cam, Item* item)
{
	self.begin_ink();
	self.ensure_mesh(item.ink);
	self.set_ink_state(cam, item.pos, item.scale, item.color);
	rl::gl_enable_vertex_array(item.ink.vao);
	rl::gl_draw_vertex_array(0, item.ink.vertex_count);
}

<*
 Draws a stroke that is still being made. It is re-tessellated every frame, so it goes
 through one shared buffer rather than a mesh of its own.
*>
fn void Renderer.draw_live(&self, Camera* cam, InkPoint[] points, bool smooth, Tip tip, DVec2 pos, Rgba color)
{
	if (!points.len) return;
	geom::tessellate(points, smooth, tip, &self.verts, &self.flat);
	Vec2[] verts = self.verts.array_view();
	int bytes = (int)verts.len * Vec2::size;
	self.begin_ink();
	if (bytes > self.live_capacity)
	{
		if (self.live_vao)
		{
			rl::gl_unload_vertex_array(self.live_vao);
			rl::gl_unload_vertex_buffer(self.live_vbo);
		}
		self.live_capacity = math::max(bytes * 2, LIVE_INITIAL_CAPACITY);
		self.live_vao = rl::gl_load_vertex_array();
		rl::gl_enable_vertex_array(self.live_vao);
		self.live_vbo = rl::gl_load_vertex_buffer(null, self.live_capacity, true);
		rl::gl_set_vertex_attribute(0, 2, GL_FLOAT, false, 0, 0);
		rl::gl_enable_vertex_attribute(0);
		rl::gl_disable_vertex_array();
	}
	rl::gl_enable_vertex_array(self.live_vao);
	rl::gl_update_vertex_buffer(self.live_vbo, verts.ptr, bytes, 0);
	self.set_ink_state(cam, pos, 1, color);
	rl::gl_draw_vertex_array(0, (int)verts.len);
	self.end_ink();
}

fn void upload_picture(Asset* asset, RLImage* image)
{
	int longest = math::max(image.width, image.height);
	if (longest > MAX_TEXTURE_SIZE)
	{
		float fit = (float)MAX_TEXTURE_SIZE / longest;
		rl::image_resize(image, (int)(image.width * fit), (int)(image.height * fit));
	}
	asset.texture = rl::load_texture_from_image(*image);
	if (!asset.texture.id)
	{
		asset.state = FAILED;
		return;
	}
	rl::gen_texture_mipmaps(&asset.texture);
	asset.texture.set_filter(TRILINEAR);
	asset.texture.set_wrap(CLAMP);
	asset.state = READY;
	asset.texture_bytes = (long)asset.texture.width * asset.texture.height * 4 * 4 / 3; // RGBA and its mipmaps
}

// The picture loads again from the asset's own bytes the next time it is drawn.
fn void drop_texture(Asset* asset)
{
	rl::unload_texture(asset.texture);
	asset.texture = {};
	asset.state = UNLOADED;
}

<*
 Applies a JPEG's EXIF orientation, so phone photos are not shown sideways.
*>
fn void orient_image(RLImage* image, int orientation)
{
	switch (orientation)
	{
		case 2: rl::image_flip_horizontal(image);
		case 3:
			rl::image_rotate_cw(image);
			rl::image_rotate_cw(image);
		case 4: rl::image_flip_vertical(image);
		case 5:
			rl::image_rotate_cw(image);
			rl::image_flip_horizontal(image);
		case 6: rl::image_rotate_cw(image);
		case 7:
			rl::image_rotate_ccw(image);
			rl::image_flip_horizontal(image);
		case 8: rl::image_rotate_ccw(image);
		default: break;
	}
}

fn void Renderer.ensure_texture(&self, Asset* asset)
{
	if (asset.state != UNLOADED) return;
	if (!self.load_all_textures && self.textures_left <= 0)
	{
		self.textures_waiting = true;
		return;
	}
	self.textures_left--;
	@pool()
	{
		RLImage image = rl::load_image_from_memory(asset.extension.zstr_tcopy(), asset.bytes.ptr, (int)asset.bytes.len);
		if (!image.data)
		{
			asset.state = FAILED;
			return;
		}
		orient_image(&image, geom::jpeg_orientation(asset.bytes));
		upload_picture(asset, &image);
		rl::unload_image(image);
	};
}

fn void Renderer.draw_image(&self, Camera* cam, Item* item)
{
	self.end_ink();
	Asset* asset = item.asset;
	asset.last_drawn = self.frame;
	self.ensure_texture(asset);
	Vec2 p = cam.to_screen(item.pos);
	float s = (float)(item.scale * cam.zoom);
	RLRectangle dest = { .x = p.x, .y = p.y, .width = item.size.x * s, .height = item.size.y * s };
	if (asset.state != READY)
	{
		rl::draw_rectangle_rec(dest, { 200, 200, 205, 255 });
		return;
	}
	RLRectangle source = { .width = asset.texture.width, .height = asset.texture.height };
	rl::draw_texture_pro(asset.texture, source, dest, { 0, 0 }, 0, { 255, 255, 255, 255 });
}

fn float Renderer.advance(&self, int codepoint)
{
	RLFont* font = &self.text_font;
	int index = rl::get_glyph_index(*font, codepoint);
	int advance = font.glyphs[index].advance_x;
	float pixels = advance ? (float)advance : font.recs[index].width;
	return pixels * TEXT_SIZE / font.base_size;
}

fn int next_codepoint(String text, sz at, sz* size)
{
	*size = text.len - at;
	Char32? codepoint = conv::utf8_to_char32(&text[at], size);
	if (catch codepoint)
	{
		*size = 1;
		return '?';
	}
	return (int)codepoint;
}

<*
 Breaks text into lines, word-wrapping when `wrap` is positive.
*>
fn void Renderer.layout(&self, String text, float wrap, List{Line}* out)
{
	out.clear();
	sz at = 0;
	sz line_start = 0;
	sz last_space = -1;
	float x = 0;
	float x_at_space = 0;
	while (at < text.len)
	{
		sz size;
		int codepoint = next_codepoint(text, at, &size);
		if (codepoint == '\n')
		{
			out.push({ line_start, at, x });
			at += size;
			line_start = at;
			x = 0;
			last_space = -1;
			continue;
		}
		float advance = self.advance(codepoint);
		if (wrap > 0 && x + advance > wrap && at > line_start)
		{
			if (last_space >= 0)
			{
				out.push({ line_start, last_space, x_at_space });
				at = last_space + 1;
			}
			else
			{
				out.push({ line_start, at, x });
			}
			line_start = at;
			x = 0;
			last_space = -1;
			continue;
		}
		if (codepoint == ' ')
		{
			last_space = at;
			x_at_space = x;
		}
		x += advance;
		at += size;
	}
	out.push({ line_start, text.len, x });
}

<*
 The local size a text needs, for a note of the given width or free-standing text.
*>
fn Vec2 Renderer.measure(&self, String text, float wrap)
{
	self.layout(text, wrap, &self.lines);
	float width = 0;
	foreach (line : self.lines) width = math::max(width, line.width);
	return { width, self.lines.len() * LINE_HEIGHT };
}

<*
 Where the caret sits inside a text box, in local units from the first character.
*>
fn Vec2 Renderer.caret_position(&self, String text, float wrap, sz caret)
{
	self.layout(text, wrap, &self.lines);
	foreach (i, line : self.lines)
	{
		bool last = i + 1 == self.lines.len();
		if (caret > line.end || (caret == line.end && !last && self.lines[i + 1].start == caret)) continue;
		float x = 0;
		sz at = line.start;
		while (at < caret && at < line.end)
		{
			sz size;
			x += self.advance(next_codepoint(text, at, &size));
			at += size;
		}
		return { x, i * LINE_HEIGHT };
	}
	return { 0, 0 };
}

fn void Renderer.draw_text(&self, Camera* cam, Item* item)
{
	self.end_ink();
	String text = item.id == self.edit_id ? self.edit_text : item.text.text;
	float s = (float)(item.scale * cam.zoom);
	Vec2 p = cam.to_screen(item.pos);
	bool note = item.fill.a > 0;
	if (note)
	{
		RLRectangle box = { .x = p.x, .y = p.y, .width = item.size.x * s, .height = item.size.y * s };
		RLRectangle shadow = { .x = box.x + 2 * s, .y = box.y + 5 * s, .width = box.width, .height = box.height };
		rl::draw_rectangle_rounded(shadow, 0.015f, 6, { 0, 0, 0, 34 });
		rl::draw_rectangle_rounded(box, 0.015f, 6, item.fill);
	}
	float pad = note ? NOTE_PAD : 0;
	float wrap = note ? item.size.x - NOTE_PAD * 2 : 0;
	self.layout(text, wrap, &self.lines);
	float font_size = TEXT_SIZE * s;
	float y = p.y + pad * s;
	float line_height = LINE_HEIGHT * s;
	if (font_size < 3.5f)
	{
		// Too small to read: suggest the lines rather than draw illegible glyphs.
		foreach (line : self.lines)
		{
			Rgba faint = { item.color.r, item.color.g, item.color.b, 90 };
			rl::draw_rectangle_rec({ .x = p.x + pad * s, .y = y + line_height * 0.3f, .width = line.width * s, .height = line_height * 0.4f }, faint);
			y += line_height;
		}
		return;
	}
	rl::begin_shader_mode(self.sdf_shader);
	foreach (line : self.lines)
	{
		if (y + line_height >= 0 && y <= self.height)
		{
			float x = p.x + pad * s;
			sz at = line.start;
			while (at < line.end)
			{
				sz size;
				int codepoint = next_codepoint(text, at, &size);
				rl::draw_text_codepoint(self.text_font, codepoint, { x, y }, font_size, item.color);
				x += self.advance(codepoint) * s;
				at += size;
			}
		}
		y += line_height;
	}
	rl::end_shader_mode();
}

fn void Renderer.draw_items(&self, Board* board, Camera* cam)
{
	DRect view = { .lo = cam.to_world({ 0, 0 }), .hi = cam.to_world({ (float)self.width, (float)self.height }) };
	foreach (item : board.items)
	{
		if (item.dead) continue;
		DRect box = item.bounds();
		if (!box.overlaps(view)) continue;
		DVec2 on_screen = box.size() * cam.zoom;
		if (on_screen.x < 0.2 && on_screen.y < 0.2) continue;
		switch (item.kind)
		{
			case INK: self.draw_ink(cam, item);
			case IMAGE: self.draw_image(cam, item);
			case TEXT: self.draw_text(cam, item);
		}
	}
	self.end_ink();
}

fn bool on_five(double index) @local => index - 5 * math::floor(index / 5) == 0;

<*
 Fades the marks in and out across zoom levels, so the paper always shows a sense of
 scale: as one spacing gets too dense, the next coarser one takes over.
*>
fn void Renderer.draw_paper(&self, Camera* cam, char paper, char pattern)
{
	Paper style = PAPERS[paper % PAPERS.len];
	rl::clear_background(style.color);
	if (pattern >= Pattern::len) return;
	Pattern kind = Pattern::from_ordinal(pattern);
	if (kind == PLAIN) return;

	const double MIN_SPACING = 14;
	double spacing = math::pow(5.0, math::ceil(math::log(MIN_SPACING / cam.zoom, 5.0)));
	double on_screen = spacing * cam.zoom; // from MIN_SPACING up to five times that
	float fade = (float)math::clamp((on_screen - MIN_SPACING) / (MIN_SPACING * 4), 0.0, 1.0);

	double first_x = math::floor(cam.origin.x / spacing);
	double first_y = math::floor(cam.origin.y / spacing);
	float start_x = (float)((first_x * spacing - cam.origin.x) * cam.zoom);
	float start_y = (float)((first_y * spacing - cam.origin.y) * cam.zoom);
	int columns = (int)(self.width / on_screen) + 2;
	int rows = (int)(self.height / on_screen) + 2;
	Rgba minor = style.mark;
	minor.a = (char)(style.mark.a * fade);
	Rgba major = style.mark;

	if (kind == GRID)
	{
		for (int i = 0; i < columns; i++)
		{
			float x = start_x + (float)(i * on_screen);
			bool is_major = on_five(first_x + i);
			rl::draw_rectangle_rec({ .x = x, .y = 0, .width = 1, .height = self.height }, is_major ? major : minor);
		}
		for (int j = 0; j < rows; j++)
		{
			float y = start_y + (float)(j * on_screen);
			bool is_major = on_five(first_y + j);
			rl::draw_rectangle_rec({ .x = 0, .y = y, .width = self.width, .height = 1 }, is_major ? major : minor);
		}
		return;
	}
	for (int j = 0; j < rows; j++)
	{
		float y = start_y + (float)(j * on_screen);
		bool major_row = on_five(first_y + j);
		for (int i = 0; i < columns; i++)
		{
			float x = start_x + (float)(i * on_screen);
			bool is_major = major_row && on_five(first_x + i);
			if (!is_major && minor.a < 3) continue;
			float size = is_major ? 2.5f : 1.5f;
			rl::draw_rectangle_rec({ .x = x - size / 2, .y = y - size / 2, .width = size, .height = size }, is_major ? major : minor);
		}
	}
}

<*
 Renders part of the board to a PNG. The picture is drawn at twice the output size and
 scaled down, which stands in for the window's multisampling.

 @return "false when the GPU could not provide the render target or the file could not be written"
*>
fn bool Renderer.export_png(&self, Board* board, DRect area, char paper, ZString path, int longest_side = 4096)
{
	DVec2 size = area.size();
	double fit = (double)(longest_side * 2) / math::max(size.x, size.y, 1e-9);
	Camera cam = { .origin = area.lo, .zoom = fit };
	int width = math::clamp((int)(size.x * fit), 2, longest_side * 2);
	int height = math::clamp((int)(size.y * fit), 2, longest_side * 2);

	RLRenderTexture target = rl::load_render_texture(width, height);
	if (!target.id) return false;
	defer rl::unload_render_texture(target);

	// raylib's render textures have no stencil, which translucent ink relies on.
	uint stencil;
	gl_gen_renderbuffers(1, &stencil);
	defer gl_delete_renderbuffers(1, &stencil);
	gl_bind_renderbuffer(GL_RENDERBUFFER, stencil);
	gl_renderbuffer_storage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width, height);
	gl_bind_framebuffer(GL_FRAMEBUFFER, target.id);
	gl_framebuffer_renderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, stencil);
	bool complete = rl::gl_framebuffer_complete(target.id);
	gl_bind_framebuffer(GL_FRAMEBUFFER, 0);
	if (!complete) return false;

	int saved_width = self.width;
	int saved_height = self.height;
	self.load_all_textures = true;
	rl::begin_texture_mode(target);
	rl::clear_background(PAPERS[paper % PAPERS.len].color);
	self.begin_scene(width, height);
	self.draw_items(board, &cam);
	rl::end_texture_mode();
	self.load_all_textures = false;
	self.width = saved_width;
	self.height = saved_height;

	RLImage image = rl::load_image_from_texture(target.texture);
	defer rl::unload_image(image);
	rl::image_flip_vertical(&image);
	rl::image_resize(&image, width / 2, height / 2);
	// Blending also lowers the target's alpha under translucent ink, though the colours
	// are right. Keeping those alpha values would punch see-through holes in the PNG.
	rl::image_format(&image, UNCOMPRESSED_R8G8B8);
	return rl::export_image(image, path);
}
