// End-to-end test: scripted input through the real update and render path, on a real GL
// context. Built only into the tabla-e2e target. It asserts on the document and saves
// screenshots into the directory it is given.
module tabla @feat(E2E);
import tabla::app, tabla::board, tabla::geom, tabla::input, tabla::render, tabla::clip, tabla::store, tabla::ui, tabla::dialog;
import raylib55::rl;
import std::io, std::math, std::os::env, std::collections::list;

extern fn CInt c_symlink(ZString target, ZString link) @cname("symlink");

struct Script
{
	App* a;
	String dir;
	int checks;
	int failures;
}

fn void Script.check(&self, bool ok, String what)
{
	self.checks++;
	if (ok) return;
	self.failures++;
	io::printfn("  FAILED: %s", what);
}

fn void Script.near(&self, double got, double want, String what)
{
	bool ok = math::abs(got - want) <= 1e-6 + math::abs(want) * 1e-6;
	if (!ok) io::printfn("  got %f, wanted %f", got, want);
	self.check(ok, what);
}

fn void Script.section(&self, String name) => io::printfn("== %s", name);

fn void Script.step(&self)
{
	Input* in = &self.a.input;
	in.time += 1.0 / 60;
	in.dt = 1.0f / 60;
	in.width = rl::get_screen_width();
	in.height = rl::get_screen_height();
	self.a.frame();
	in.left_pressed = false;
	in.left_released = false;
	in.pan_pressed = false;
	in.wheel = 0;
	in.pressed = {};
	in.first_press = {};
	in.letters = {};
	in.first_letters = {};
	in.char_count = 0;
	in.trail_count = 0;
	in.delta = { 0, 0 };
}

fn void Script.settle_camera(&self)
{
	for (int i = 0; i < 300 && self.a.camera_moving(); i++) self.step();
}

fn void Script.move_to(&self, Vec2 p, int steps = 1)
{
	Input* in = &self.a.input;
	Vec2 from = in.mouse;
	for (int i = 1; i <= steps; i++)
	{
		Vec2 q = from + (p - from) * ((float)i / steps);
		in.delta = q - in.mouse;
		in.mouse = q;
		in.trail[0] = { q, in.time };
		in.trail_count = 1;
		self.step();
	}
}

fn void Script.press(&self)
{
	self.a.input.left_down = true;
	self.a.input.left_pressed = true;
	self.step();
}

fn void Script.release(&self)
{
	self.a.input.left_down = false;
	self.a.input.left_released = true;
	self.step();
}

fn void Script.drag(&self, Vec2 from, Vec2 to, int steps = 12)
{
	self.move_to(from);
	self.press();
	self.move_to(to, steps);
	self.release();
}

// Draws through a list of points as one continuous stroke.
fn void Script.scribble(&self, Vec2[] points)
{
	self.move_to(points[0]);
	self.press();
	foreach (p : points[1..]) self.move_to(p, 6);
	self.release();
}

fn void Script.click(&self, Vec2 at)
{
	self.move_to(at);
	self.press();
	self.release();
}

fn void Script.tap(&self, RLKeyboardKey key)
{
	self.a.input.pressed[(int)key] = true;
	self.step();
}

fn void Script.letter(&self, char c, bool ctrl = false, bool shift = false)
{
	Input* in = &self.a.input;
	in.letters[c - 'a'] = true;
	in.first_letters[c - 'a'] = true;
	in.ctrl = ctrl;
	in.shift = shift;
	self.step();
	in.ctrl = false;
	in.shift = false;
}

fn void Script.type(&self, String text)
{
	Input* in = &self.a.input;
	sz at = 0;
	while (at < text.len)
	{
		sz size;
		in.chars[0] = render::next_codepoint(text, at, &size);
		in.char_count = 1;
		at += size;
		self.step();
	}
}

fn void Script.wheel(&self, Vec2 at, float amount)
{
	self.move_to(at);
	self.a.input.wheel = amount;
	self.step();
	self.settle_camera();
}

fn String Script.file(&self, String name) => string::format(mem, "%s/%s", self.dir, name);

fn String Script.fresh(&self, String name)
{
	String path = self.file(name);
	(void)file::delete(path);
	return path;
}

// Closes the board and loads it back from its file, the way a new session would.
fn void Script.reopen(&self)
{
	App* a = self.a;
	Tab* board = a.tab;
	String path = board.path.copy(mem);
	a.new_board(self.fresh("reopen-spare.tabla"));
	Tab* spare = a.tab;
	self.check(a.close_tab(board), "closing a board to reopen it");
	self.check(a.open(path), "reopening it");
	self.check(a.close_tab(spare), "closing the spare tab");
	free(path);
}

fn Vec2 Script.tab_at(&self, int index)
{
	Ui* u = &self.a.ui;
	return { u.tab_strip.x + 6 + u.tab_width * (index + 0.5f), u.tab_strip.y + 5 + ui::BUTTON * 0.5f };
}

fn Vec2 Script.tab_cross(&self, int index)
{
	Ui* u = &self.a.ui;
	return { u.tab_strip.x + 6 + u.tab_width * (float)(index + 1) - 16, u.tab_strip.y + 5 + ui::BUTTON * 0.5f };
}

fn void Script.ctrl_key(&self, RLKeyboardKey key, bool shift = false)
{
	Input* in = &self.a.input;
	in.ctrl = true;
	in.shift = shift;
	in.first_press[(int)key] = true;
	self.tap(key);
	in.ctrl = false;
	in.shift = false;
}

fn sz Script.saved_items(&self, String path)
{
	Board check;
	check.init();
	defer check.free();
	if (catch store::load(&check, path)) return -1;
	return check.items.len();
}

fn void Script.wait_for_dialog(&self)
{
	for (int i = 0; i < 400 && dialog::is_open(); i++)
	{
		self.step();
		rl::wait_time(0.005);
	}
	self.step();
}

fn void Script.shot(&self, String name)
{
	self.a.capture_path = self.file(name);
	self.step();
}

fn int Script.count(&self, ItemKind kind)
{
	int n = 0;
	foreach (item : self.a.tab.board.items)
	{
		if (!item.dead && item.kind == kind) n++;
	}
	return n;
}

fn Item* Script.top(&self) => self.a.tab.board.items[self.a.tab.board.items.len() - 1];

fn void make_test_picture(ZString path, RLColor sky)
{
	RLImage image = rl::gen_image_gradient_linear(640, 420, 0, sky, { 250, 225, 190, 255 });
	rl::image_format(&image, UNCOMPRESSED_R8G8B8A8);
	rl::image_draw_circle(&image, 470, 120, 60, { 255, 236, 150, 255 });
	rl::image_draw_triangle(&image, { 40, 420 }, { 300, 420 }, { 180, 170 }, { 70, 95, 120, 255 });
	rl::image_draw_triangle(&image, { 200, 420 }, { 640, 420 }, { 430, 210 }, { 50, 75, 100, 255 });
	rl::export_image(image, path);
	rl::unload_image(image);
}

fn RLColor pixel(String path, int x, int y)
{
	RLImage image = rl::load_image(path.zstr_tcopy());
	defer rl::unload_image(image);
	return rl::get_image_color(image, x, y);
}

fn void Script.test_pens(&self)
{
	self.section("pens and markers");
	App* a = self.a;
	Vec2[*] wave = { { 240, 170 }, { 320, 120 }, { 400, 200 }, { 480, 120 }, { 560, 200 }, { 640, 150 } };
	a.set_tool(PEN);
	self.scribble(&wave);
	self.check(self.count(INK) == 1, "pen makes a stroke");
	self.check(self.top().ink.tip == ROUND, "pen has a round tip");
	self.check(self.top().ink.points.len > 10, "stroke keeps its samples");

	foreach (&p : wave) p.y += 100;
	a.set_tool(BRUSH);
	self.scribble(&wave);
	float thin = float::max;
	float thick = 0;
	foreach (p : self.top().ink.points)
	{
		thin = math::min(thin, p.w);
		thick = math::max(thick, p.w);
	}
	self.check(thick > thin * 1.5f, "brush width varies along the stroke");

	foreach (&p : wave) p.y += 100;
	a.set_tool(MARKER);
	self.scribble(&wave);
	self.check(self.top().ink.tip == CHISEL, "marker has a chisel tip");

	foreach (&p : wave) p.y += 100;
	a.set_tool(HIGHLIGHTER);
	self.scribble(&wave);
	self.check(self.top().ink.tip == WEDGE, "highlighter has its own tip");
	self.check(self.top().color.a < 255, "highlighter is translucent");

	// A highlighter stroke crossing itself must not get darker at the crossing.
	Vec2[*] loop = { { 760, 140 }, { 980, 140 }, { 980, 300 }, { 860, 300 }, { 860, 60 } };
	a.set_tool(PEN); // sharp corners, no filter lag
	a.styles[Tool.HIGHLIGHTER.ordinal].smoothing = 0;
	a.set_tool(HIGHLIGHTER);
	self.scribble(&loop);
	self.move_to({ 1100, 500 });
	self.shot("01-pens.png");
	@pool()
	{
		String shot = self.file("01-pens.png");
		RLColor crossing = pixel(shot, 860, 140);
		RLColor single = pixel(shot, 920, 140);
		self.check(crossing == single, "translucent ink shows no overlap");
		self.check(single.b < 200, "highlighter is visible on the paper");
	};
	a.styles[Tool.HIGHLIGHTER.ordinal].smoothing = 0.5f;
}

fn void Script.test_undo_of_everything(&self)
{
	self.section("undo and redo");
	App* a = self.a;
	sz items = a.tab.board.items.len();
	sz steps = a.tab.board.undo_steps.len();
	for (sz i = 0; i < steps; i++) a.undo();
	self.step();
	self.check(a.tab.board.items.len() == 0, "undoing everything empties the board");
	for (sz i = 0; i < steps; i++) a.redo();
	self.step();
	self.check(a.tab.board.items.len() == items, "redo brings everything back");
}

fn void Script.test_shapes(&self)
{
	self.section("lines and shapes");
	App* a = self.a;
	Input* in = &a.input;
	a.tool = LINE;
	sz before = a.tab.board.items.len();
	self.drag({ 240, 620 }, { 400, 720 });
	self.check(a.tab.board.items.len() == before + 1, "line");
	a.tool = ARROW;
	self.drag({ 430, 620 }, { 590, 720 });
	self.check(self.top().ink.points.len == 5, "arrow has a head");
	a.tool = RECT;
	self.drag({ 620, 620 }, { 780, 720 });
	self.check(self.top().ink.points.len == 5, "rectangle outline");
	a.tool = ELLIPSE;
	self.drag({ 810, 620 }, { 970, 720 });

	a.tool = RECT;
	self.move_to({ 1000, 620 });
	in.shift = true;
	self.drag({ 1000, 620 }, { 1100, 680 });
	in.shift = false;
	DRect box = self.top().bounds();
	DVec2 size = box.size();
	self.near(size.x, size.y, "shift makes a square");

	before = a.tab.board.items.len();
	self.click({ 1150, 700 });
	self.check(a.tab.board.items.len() == before, "a click makes no shape");
	self.shot("02-shapes.png");
}

fn void Script.test_pictures(&self)
{
	self.section("pictures: add, draw on, move, resize");
	App* a = self.a;
	Board* b = &a.tab.board;
	String path = self.file("picture.png");
	make_test_picture(path.zstr_tcopy(), { 90, 160, 220, 255 });

	// A fresh canvas position, away from the earlier drawings.
	a.pan_by({ 0, -1000 });
	String[1] paths = { path };
	a.add_files(&paths, { 640, 420 });
	self.step();
	self.check(self.count(IMAGE) == 1, "picture lands on the board");
	self.check(a.tool == SELECT && a.selection.len() == 1, "new picture is selected");
	Item* picture = self.top();
	uint picture_id = picture.id;
	self.check(picture.asset.width == 640 && picture.asset.height == 420, "picture size read from the file");
	self.check(picture.asset.state == READY, "picture uploaded to the GPU");

	a.tool = MARKER;
	a.selection.clear();
	Vec2[*] circle = { { 560, 300 }, { 700, 290 }, { 760, 380 }, { 660, 460 }, { 540, 420 }, { 560, 300 } };
	self.scribble(&circle);
	Item* ink = self.top();
	uint ink_id = ink.id;
	self.check(ink.parent == picture_id, "ink started on a picture is pinned to it");

	a.tool = PEN;
	sz free_ink = b.items.len();
	self.scribble((Vec2[]){ { 1100, 200 }, { 1200, 220 } });
	self.check(self.top().parent == 0, "ink off the picture stays free");
	self.check(b.items.len() == free_ink + 1, "free stroke added");
	uint free_id = self.top().id;
	self.shot("03-drawn-on-picture.png");

	DVec2 ink_before = b.get(ink_id)!!.pos;
	DVec2 free_before = b.get(free_id)!!.pos;
	a.tool = SELECT;
	self.click({ 400, 400 });
	self.check(a.selection.len() == 1 && a.selection[0] == picture_id, "click selects the picture");
	self.drag({ 400, 400 }, { 300, 300 });
	DVec2 moved = b.get(ink_id)!!.pos - ink_before;
	self.near(moved.x, -100, "pinned ink moves with its picture");
	self.near(moved.y, -100, "pinned ink moves with its picture (y)");
	self.check(b.get(free_id)!!.pos == free_before, "free ink stays where it was");
	self.shot("04-picture-moved.png");

	// Drag the bottom-right handle out to 150%: the ink must stay on the same spot.
	Item* p = b.get(picture_id)!!;
	Item* i = b.get(ink_id)!!;
	Vec2 relative = (Vec2)((i.pos - p.pos) / p.scale);
	double old_scale = p.scale;
	double old_ink_scale = i.scale;
	DRect box = p.bounds();
	Vec2 corner = a.tab.cam.to_screen(box.hi);
	Vec2 lo = a.tab.cam.to_screen(box.lo);
	self.drag(corner, lo + (corner - lo) * 1.5f);
	p = b.get(picture_id)!!;
	i = b.get(ink_id)!!;
	self.near(p.scale, old_scale * 1.5, "corner handle scales the picture");
	self.near(i.scale, old_ink_scale * 1.5, "pinned ink scales with it");
	Vec2 after = (Vec2)((i.pos - p.pos) / p.scale);
	self.check(geom::length(after - relative) < 0.01f, "pinned ink stays on the same spot of the picture");
	self.shot("05-picture-resized.png");

	// Resizing and moving are a single undo step each, and take the ink along.
	a.undo();
	self.near(b.get(picture_id)!!.scale, old_scale, "undo the resize");
	a.undo();
	self.check(b.get(ink_id)!!.pos == ink_before, "undo the move, ink included");
	a.redo();
	a.redo();

	// Deleting the picture removes what is drawn on it; undo restores both.
	a.selection.clear();
	a.selection.push(picture_id);
	a.delete_selection();
	self.step();
	self.check(!b.by_id.has_key(ink_id), "deleting a picture deletes its ink");
	a.undo();
	self.step();
	self.check(b.by_id.has_key(ink_id) && b.by_id.has_key(picture_id), "undo restores the picture and its ink");

	// Layer order: a second picture goes on top, then the first comes back up with its ink.
	String second_path = self.file("picture2.png");
	make_test_picture(second_path.zstr_tcopy(), { 200, 110, 150, 255 });
	String[1] second = { second_path };
	a.add_files(&second, { 500, 400 });
	self.step();
	self.check(self.count(IMAGE) == 2, "second picture");
	self.check(b.assets.len() == 2, "second asset");
	a.selection.clear();
	a.selection.push(picture_id);
	a.bring_to_front();
	self.step();
	self.check(self.top().id == ink_id, "ink stays above its picture when raised");
	a.send_to_back();
	self.step();
	self.check(b.items[0].id == picture_id, "picture sent to the back");
	self.check(b.items[1].id == ink_id, "its ink directly follows");
	a.bring_to_front();
	self.step();
}

fn void Script.test_eraser(&self)
{
	self.section("eraser");
	App* a = self.a;
	a.reset_view();
	a.pan_by({ -3000, 0 });
	self.step();
	a.tool = LINE;
	a.styles[Tool.LINE.ordinal].size = 8;
	self.drag({ 300, 300 }, { 900, 300 });
	sz before = a.tab.board.items.len();
	uint line_id = self.top().id;
	a.tool = ERASER;
	self.drag({ 600, 220 }, { 600, 380 });
	self.check(a.tab.board.items.len() == before + 1, "eraser cuts the line in two");
	self.check(!a.tab.board.by_id.has_key(line_id), "the original was replaced");
	sz steps = a.tab.board.undo_steps.len();
	self.shot("06-erased.png");
	a.undo();
	self.step();
	self.check(a.tab.board.by_id.has_key(line_id) && a.tab.board.items.len() == before, "one undo restores the whole line");
	a.redo();
	self.step();
	self.check(a.tab.board.undo_steps.len() == steps, "redo reapplies the cut");

	Input* in = &a.input;
	in.shift = true;
	self.drag({ 400, 250 }, { 400, 350 });
	in.shift = false;
	self.check(a.tab.board.items.len() == before, "Shift erases whole strokes");
	a.undo();
	a.styles[Tool.LINE.ordinal].size = 3;
	self.step();

	// Erasing ink pinned to a picture keeps the remains pinned.
	a.tool = LINE;
}

fn void Script.test_text(&self)
{
	self.section("text and sticky notes");
	App* a = self.a;
	a.reset_view();
	a.pan_by({ 3000, 0 });
	self.step();
	a.tool = TEXT;
	self.click({ 260, 160 });
	self.check(a.edit_id != 0, "clicking starts typing");
	self.type("Šđčćž Ś Ź");
	self.tap(ENTER);
	self.type("Ćirilica: Љубав њежна");
	Item* text = a.tab.board.get(a.edit_id)!!;
	uint text_id = text.id;
	self.tap(BACKSPACE);
	self.type("a!");
	self.check(a.edit_string() == "Šđčćž Ś Ź\nĆirilica: Љубав њежнa!", "typing and backspace across UTF-8");
	self.tap(LEFT);
	self.tap(LEFT);
	self.tap(BACKSPACE);
	self.check(a.edit_string() == "Šđčćž Ś Ź\nĆirilica: Љубав њежa!", "caret moves by characters");
	self.tap(END);
	self.shot("07-typing.png");
	self.tap(ESCAPE);
	self.check(a.edit_id == 0, "Escape finishes");
	self.check(a.tab.board.get(text_id)!!.text.text == "Šđčćž Ś Ź\nĆirilica: Љубав њежa!", "text is stored");
	self.check(a.tab.board.undo_steps.len() > 0, "text is undoable");

	a.tool = TEXT;
	sz before = a.tab.board.items.len();
	self.click({ 700, 500 });
	self.tap(ESCAPE);
	self.check(a.tab.board.items.len() == before, "empty text leaves nothing behind");

	// Clicking away ends the typing, and only that.
	a.tool = TEXT;
	before = a.tab.board.items.len();
	self.click({ 900, 600 });
	self.type("gone soon");
	self.click({ 950, 700 });
	self.check(a.edit_id == 0, "clicking away ends typing");
	self.check(a.tab.board.items.len() == before + 1, "and does not start another text");
	a.undo();
	self.step();

	a.tool = NOTE;
	self.click({ 400, 480 });
	self.type("Sticky notes wrap their text automatically when a line gets long. They also grow when they run out of room, as this one does because it has quite a lot to say about itself.");
	Item* note = a.tab.board.get(a.edit_id)!!;
	uint note_id = note.id;
	self.check(note.size.y > app::NOTE_SIZE, "a note grows with its text");
	self.tap(ESCAPE);

	a.tool = SELECT;
	Vec2 on_note = a.tab.cam.to_screen(a.tab.board.get(note_id)!!.pos) + (Vec2){ 30, 30 };
	self.click(on_note);
	self.check(a.is_selected(note_id), "notes are selectable");
	a.input.time += 1; // the next click is not a double click
	self.click(on_note);
	self.click(on_note);
	self.check(a.edit_id == note_id, "double click edits");
	self.tap(ESCAPE);

	a.tool = NOTE;
	a.styles[Tool.NOTE.ordinal].color = ui::NOTE_COLORS[4];
	self.click({ 760, 340 });
	self.type("Plan");
	self.tap(ESCAPE);
	a.tool = SELECT;
	self.move_to({ 1100, 700 });
	self.shot("08-text.png");
}

fn void Script.test_zoom(&self)
{
	self.section("infinite canvas");
	App* a = self.a;
	a.reset_view();
	self.step();
	Vec2 mouse = { 500, 300 };
	DVec2 before = a.tab.cam.to_world(mouse);
	self.wheel(mouse, 6);
	self.check(a.tab.cam.zoom > 2.5, "wheel zooms in");
	DVec2 after = a.tab.cam.to_world(mouse);
	self.near(after.x, before.x, "the spot under the mouse stays put (x)");
	self.near(after.y, before.y, "the spot under the mouse stays put (y)");

	// Far from the origin the coordinates are enormous, and a stroke must still be exact.
	a.tab.cam = { .origin = { 4e12, -7e12 }, .zoom = 3000 };
	a.tab.cam_target = a.tab.cam;
	a.tool = PEN;
	a.styles[Tool.PEN.ordinal].size = 6;
	Vec2[*] zig = { { 300, 300 }, { 400, 200 }, { 500, 300 }, { 600, 200 }, { 700, 300 }, { 800, 200 } };
	self.scribble(&zig);
	Item* far_ink = self.top();
	self.check(far_ink.pos.x > 3.9e12, "the stroke lives far away");
	self.near(far_ink.ink.points[0].w * far_ink.scale * a.tab.cam.zoom, 6.0, "pen width is in screen pixels");
	self.move_to({ 1100, 700 });
	self.shot("09-far-away.png");
	@pool()
	{
		// The zig-zag starts near (300,300). Any precision loss would smear it around.
		RLColor c = pixel(self.file("09-far-away.png"), 350, 250);
		self.check(c.r < 90, "ink is sharp at 4e12 world units from the origin");
	};
	a.styles[Tool.PEN.ordinal].size = 3;

	// Going down the scale: draw at tiny size inside a huge zoom-in.
	a.tab.cam = { .origin = { 100, 100 }, .zoom = 50000 };
	a.tab.cam_target = a.tab.cam;
	self.step();
	self.shot("10-deep-zoom.png");

	a.fit_all();
	self.settle_camera();
	self.check(a.tab.cam.zoom < 1, "fit reaches everything");
	self.shot("11-fit-all.png");
	a.reset_view();
	self.step();
}

fn void Script.test_copy_paste(&self)
{
	self.section("copy, paste, duplicate");
	App* a = self.a;
	Board* b = &a.tab.board;

	// Find the picture with ink on it.
	Item* picture = null;
	foreach (item : b.items)
	{
		if (item.kind != INK || !item.parent) continue;
		Item*? parent = b.get(item.parent);
		if (try parent) picture = parent;
	}
	self.check(picture != null, "a picture with ink exists");
	uint picture_id = picture.id;
	sz before = b.items.len();
	int pictures = self.count(IMAGE);
	a.selection.clear();
	a.selection.push(picture_id);
	a.duplicate();
	self.step();
	self.check(self.count(IMAGE) == pictures + 1, "duplicate copies the picture");
	self.check(b.items.len() > before + 1, "duplicate brings the ink along");
	self.check(a.selection.len() == 1, "only the copied picture ends up selected");
	self.check(a.selection[0] != picture_id, "the copy is the selection");
	uint copy_id = a.selection[0];
	Item* copy_ink = self.top();
	self.check(copy_ink.parent == copy_id, "copied ink is pinned to the copied picture");
	self.check(b.assets.len() == 2, "a duplicate shares the picture data");
	self.check(a.clip_items.is_empty(), "duplicate leaves the copy buffer alone");
	a.undo();
	self.step();
	self.check(b.items.len() == before, "undo removes the copy");

	// Copy and paste: the copy outlives the frame it was made in.
	a.selection.clear();
	a.selection.push(picture_id);
	a.copy();
	for (int i = 0; i < 3; i++) self.step();
	a.place_copies(&a.clip_items, { 9000, 9000 });
	self.step();
	self.check(self.count(IMAGE) == pictures + 1, "paste adds the picture");
	self.check(self.top().parent == a.selection[0], "pasted ink is pinned to the pasted picture");
	a.undo();
	self.step();
	self.check(b.items.len() == before, "undo removes the pasted items");
}

fn void Script.test_save_and_load(&self)
{
	self.section("save and load");
	App* a = self.a;
	a.tab.cam = { .origin = { 77, -33 }, .zoom = 0.5 };
	a.tab.cam_target = a.tab.cam;
	a.tab.paper = 1;
	a.tab.pattern = 1;
	self.step();
	sz items = self.a.tab.board.items.len();
	sz assets = a.tab.board.assets.len();
	self.check(a.save_now(true), "saving");
	self.check(!a.tab.has_unsaved(), "nothing left to save");

	String path = a.tab.path.copy(mem);
	self.reopen();
	self.step();
	self.check(a.tab.board.items.len() == items, "items come back");
	self.check(a.tab.board.assets.len() == assets, "pictures come back");
	self.near(a.tab.cam.origin.x, 77, "the view comes back");
	self.near(a.tab.cam.zoom, 0.5, "the zoom comes back");
	self.check(a.tab.paper == 1 && a.tab.pattern == 1, "paper style comes back");

	// Pictures are decoded on demand, one per frame, from the bytes inside the file.
	DRect pictures = a.tab.board.items[0].bounds();
	bool first = true;
	foreach (item : a.tab.board.items)
	{
		if (item.kind != IMAGE) continue;
		pictures = first ? item.bounds() : pictures.merge(item.bounds());
		first = false;
	}
	a.fit_view(pictures);
	self.settle_camera();
	for (int i = 0; i < 4; i++) self.step();
	bool all_ready = true;
	foreach (asset : a.tab.board.assets)
	{
		if (asset.state != READY) all_ready = false;
	}
	self.check(all_ready, "pictures decode from the saved file");
	self.shot("12-reloaded.png");

	// A broken file must not cost the open board, nor be overwritten.
	String bad = self.file("broken.tabla");
	file::save(bad, "TABLA and then nonsense")!!;
	a.open(bad);
	self.check(a.tab.board.items.len() == items, "a broken file leaves the open board alone");
	self.check(a.tab.path == path, "and the board keeps its own file");
	self.check((String)file::load_temp(bad)!! == "TABLA and then nonsense", "the broken file is untouched");

	// Autosave: change something, go idle, and the file catches up by itself.
	a.tool = PEN;
	self.scribble((Vec2[]){ { 300, 300 }, { 340, 340 } });
	self.check(a.tab.has_unsaved(), "new ink is not saved yet");
	for (int i = 0; i < 90; i++) self.step();
	self.check(!a.tab.has_unsaved(), "autosave ran after a short pause");
	Board check;
	check.init();
	defer check.free();
	(void)store::load(&check, path);
	self.check(check.items.len() == items + 1, "the autosaved file has the new stroke");
	a.tab.paper = 0;
	a.tab.pattern = 0;
}

fn void Script.test_export(&self)
{
	self.section("export");
	App* a = self.a;
	Board* b = &a.tab.board;
	a.tab.paper = 0;
	Item* picture = null;
	foreach (item : b.items)
	{
		if (item.kind != INK || !item.parent) continue;
		Item*? parent = b.get(item.parent);
		if (try parent) picture = parent;
	}
	self.check(picture != null, "a picture to export");
	uint picture_id = picture.id;
	a.fit_view(picture.bounds());
	self.settle_camera();

	// A highlighter stroke across the picture, to see translucent ink exported over pixels.
	a.styles[Tool.HIGHLIGHTER.ordinal].smoothing = 0;
	a.styles[Tool.HIGHLIGHTER.ordinal].color = { 255, 0, 200, 255 };
	a.tool = HIGHLIGHTER;
	Vec2[*] across = { { 300, 560 }, { 700, 560 } };
	self.scribble(&across);
	DVec2 highlighted = a.tab.cam.to_world({ 600, 560 });
	a.tool = SELECT;

	a.selection.clear();
	a.selection.push(picture_id);
	String path = self.file("13-export.png");
	a.export_board(path);
	self.step();
	self.check(file::exists(path), "export writes a PNG");

	DRect area = b.get(picture_id)!!.bounds();
	DVec2 margin = area.size() * 0.04 + 1e-6;
	area.lo -= margin;
	area.hi += margin;
	@pool()
	{
		RLImage image = rl::load_image(path.zstr_tcopy());
		defer rl::unload_image(image);
		self.check(image.width == 4096, "the long side is the export size");
		self.near((double)image.width / image.height, area.size().x / area.size().y, "the proportions are kept");
		RLColor at_top = rl::get_image_color(image, image.width / 2, (int)(image.height * 0.08f));
		RLColor at_bottom = rl::get_image_color(image, (int)(image.width * 0.68f), (int)(image.height * 0.9f));
		self.check(at_top.b > at_top.r + 40, "sky at the top: the export is not upside down");
		self.check(at_bottom.b < 140, "mountain at the bottom");
		RLColor corner = rl::get_image_color(image, 4, 4);
		self.check(corner.r > 240 && corner.g > 240, "the margin shows the paper");

		DVec2 scale = (DVec2){ (double)image.width, (double)image.height } / area.size();
		DVec2 at_ink = (highlighted - area.lo) * scale;
		RLColor ink = rl::get_image_color(image, (int)at_ink.x, (int)at_ink.y);
		self.check(ink.a == 255, "translucent ink leaves no holes in the PNG");
		self.check(ink.r > 150, "the highlighter is in the export");
	};

	// The stencil in the export target: on plain paper, a crossing must match a single
	// pass exactly. Stroke crossing itself at a spot nothing else has touched.
	a.reset_view();
	a.pan_by({ 0, 8000 });
	self.step();
	a.tool = HIGHLIGHTER;
	Vec2[*] loop = { { 300, 300 }, { 800, 300 }, { 800, 500 }, { 500, 500 }, { 500, 150 } };
	self.scribble(&loop);
	Item* ink = self.top();
	DVec2 crossing = a.tab.cam.to_world({ 500, 300 });
	DVec2 single = a.tab.cam.to_world({ 650, 300 });
	a.tool = SELECT;
	a.selection.clear();
	a.selection.push(ink.id);
	String crossing_path = self.file("15-export-crossing.png");
	DRect loop_area = ink.bounds();
	a.export_board(crossing_path);
	self.step();
	DVec2 loop_margin = loop_area.size() * 0.04 + 1e-6;
	loop_area.lo -= loop_margin;
	loop_area.hi += loop_margin;
	@pool()
	{
		RLImage image = rl::load_image(crossing_path.zstr_tcopy());
		defer rl::unload_image(image);
		DVec2 scale = (DVec2){ (double)image.width, (double)image.height } / loop_area.size();
		DVec2 at_crossing = (crossing - loop_area.lo) * scale;
		DVec2 at_single = (single - loop_area.lo) * scale;
		RLColor over = rl::get_image_color(image, (int)at_crossing.x, (int)at_crossing.y);
		RLColor once = rl::get_image_color(image, (int)at_single.x, (int)at_single.y);
		io::printfn("  ink once=%s crossing=%s", once, over);
		self.check(once.g < 200, "the highlighter shows on the paper");
		self.check(over == once, "crossing ink stays even in the export");
	};
	a.styles[Tool.HIGHLIGHTER.ordinal].smoothing = 0.5f;
	a.styles[Tool.HIGHLIGHTER.ordinal].color = { 252, 214, 40, 255 };
}

fn void Script.test_long_messages(&self)
{
	self.section("long messages");
	App* a = self.a;
	char[2000] long_path;
	long_path[..] = 's';
	a.toast("Could not save %s", (String)&long_path);
	self.step();
	self.check(a.toast_text.len == a.toast_buffer.len, "an oversized message is cut, not fatal");
	// A multi-byte letter across the cut must not be split in half.
	String accents = "\u0161\u0161\u0161\u0161\u0161\u0161\u0161\u0161\u0161\u0161";
	a.toast("%s%s%s%s%s%s%s%s%s%s%s", accents, accents, accents, accents, accents, accents, accents, accents, accents, accents, accents);
	self.step();
	self.check(a.toast_text.len % 2 == 0, "the cut falls between letters");
}

fn void Script.test_picture_files(&self)
{
	self.section("picture files");
	App* a = self.a;
	a.reset_view();
	a.selection.clear();
	self.step();

	// A PNG with the wrong name still opens: contents decide, not the file name.
	String renamed = self.file("really-a-png.jpg");
	char[] png = file::load(mem, self.file("picture.png"))!!;
	file::save(renamed, png)!!;
	free(png.ptr);
	int pictures = self.count(IMAGE);
	String[1] one = { renamed };
	a.add_files(&one, { 640, 400 });
	self.step();
	self.check(a.tab.board.assets.len() >= 2, "a misnamed picture is recognised");
	self.check(self.count(IMAGE) == pictures + 1, "misnamed picture added");

	String webp = self.file("photo.webp");
	file::save(webp, "RIFF\x10\0\0\0WEBPVP8 \0\0\0\0")!!;
	one = { webp };
	a.add_files(&one, { 640, 400 });
	self.step();
	self.check(a.toast_text.starts_with("WebP"), "WebP gets a clear message");

	String junk = self.file("junk.png");
	file::save(junk, "this is no picture, whatever the name says")!!;
	one = { junk };
	a.add_files(&one, { 640, 400 });
	self.step();
	self.check(a.toast_text.starts_with("Not a picture"), "junk gets a clear message");

	one = { self.file("no-such-file.png") };
	a.add_files(&one, { 640, 400 });
	self.step();
	self.check(a.toast_text.starts_with("Could not read"), "a missing file gets a clear message");
	self.check(self.count(IMAGE) == pictures + 1, "none of those added anything");

	// Orientation 6: stored as 200x100 with red on the left, shown upright as 100x200
	// with red on top. The fixture comes from scripts/e2e.sh.
	String rotated = self.file("rotated.jpg");
	if (!file::exists(rotated))
	{
		io::printn("  skipped EXIF: run scripts/e2e.sh for this part");
		return;
	}
	one = { rotated };
	a.reset_view();
	a.add_files(&one, { 640, 400 });
	self.step();
	Item* photo = self.top();
	self.check(photo.kind == IMAGE, "the JPEG is added");
	self.check(photo.asset.width == 100 && photo.asset.height == 200, "a sideways photo is stood upright");
	Vec2 lo = a.tab.cam.to_screen(photo.bounds().lo);
	Vec2 hi = a.tab.cam.to_screen(photo.bounds().hi);
	a.selection.clear();
	self.move_to({ 1200, 700 });
	self.shot("14-rotated.png");
	@pool()
	{
		String shot = self.file("14-rotated.png");
		int mid = (int)((lo.x + hi.x) * 0.5f);
		RLColor top = pixel(shot, mid, (int)(lo.y + (hi.y - lo.y) * 0.25f));
		RLColor bottom = pixel(shot, mid, (int)(lo.y + (hi.y - lo.y) * 0.75f));
		self.check(top.r > 180 && top.b < 90, "the left of the file is on top");
		self.check(bottom.b > 180 && bottom.r < 90, "the right of the file is at the bottom");
	};

	// The orientation must survive saving: the bytes keep it, not the texture.
	self.check(a.save_now(true), "saving the photo");
	uint photo_id = photo.id;
	self.reopen();
	Item* reloaded = a.tab.board.get(photo_id)!!;
	self.check(reloaded.asset.state == UNLOADED, "pictures are decoded lazily after loading");
	a.fit_view(reloaded.bounds());
	a.tab.cam = a.tab.cam_target;
	self.step();
	self.step();
	self.check(reloaded.asset.state == READY, "the reloaded photo decodes once visible");
	lo = a.tab.cam.to_screen(reloaded.bounds().lo);
	hi = a.tab.cam.to_screen(reloaded.bounds().hi);
	self.move_to({ 1200, 700 });
	self.shot("16-rotated-reloaded.png");
	@pool()
	{
		String shot = self.file("16-rotated-reloaded.png");
		int mid = (int)((lo.x + hi.x) * 0.5f);
		RLColor top = pixel(shot, mid, (int)(lo.y + (hi.y - lo.y) * 0.25f));
		RLColor bottom = pixel(shot, mid, (int)(lo.y + (hi.y - lo.y) * 0.75f));
		self.check(top.r > 180 && top.b < 90, "after reloading, red is still on top");
		self.check(bottom.b > 180 && bottom.r < 90, "and blue at the bottom");
	};
}

fn void Script.test_recovery(&self)
{
	self.section("damaged board at startup");
	String bad = self.file("damaged.tabla");
	(void)file::delete(self.file("damaged.tabla.recovered.tabla"));
	file::save(bad, "TABLA\x1a\r\ncut short")!!;
	App* b = mem::new(App);
	b.scripted = true;
	@pool()
	{
		b.init(bad);
	};
	self.check(b.tab.path.len > 0, "the app still has somewhere to save");
	self.check(b.tab.path != bad, "and it is not the damaged file");
	b.shutdown();
	self.check((String)file::load_temp(bad)!! == "TABLA\x1a\r\ncut short", "the damaged file is untouched");
	free(b);
}

// Where a tool's button sits, computed the way the rail lays itself out.
fn Vec2 Script.rail_button(&self, Tool tool)
{
	RLRectangle rail = self.a.ui.rail;
	float y = rail.y + 6;
	foreach (entry : ui::RAIL)
	{
		if (entry.gap_before) y += 11;
		if (entry.tool == tool) return { rail.x + 5 + ui::BUTTON * 0.5f, y + ui::BUTTON * 0.5f };
		y += ui::BUTTON + 2;
	}
	return { 0, 0 };
}

fn Vec2 Script.swatch_at(&self, int index)
{
	RLRectangle bar = self.a.ui.bar;
	return { bar.x + 12 + ui::SWATCH * (index + 0.5f), bar.y + bar.height * 0.5f };
}

fn void Script.test_ui(&self)
{
	self.section("toolbars, with real clicks");
	App* a = self.a;
	Board* b = &a.tab.board;
	a.reset_view();
	a.selection.clear();
	a.tool = SELECT;
	self.move_to({ 700, 400 });
	self.step();
	sz items = b.items.len();

	foreach (entry : ui::RAIL)
	{
		self.click(self.rail_button(entry.tool));
		self.check(a.tool == entry.tool, "a rail button picks its tool");
	}
	self.check(b.items.len() == items, "clicking toolbars draws nothing on the board");

	self.click(self.rail_button(MARKER));
	self.step();
	self.click(self.swatch_at(9));
	self.check(a.styles[Tool.MARKER.ordinal].color == ui::INK_COLORS[9], "a swatch sets the colour");

	// Size slider: it comes right after the 12 swatches and the custom colour button.
	RLRectangle bar = a.ui.bar;
	float slider_x = bar.x + 12 + ui::SWATCH * 13 + 14;
	float slider_y = bar.y + 2 + 29;
	float old_size = a.styles[Tool.MARKER.ordinal].size;
	self.drag({ slider_x + 10, slider_y }, { slider_x + 80, slider_y }, 4);
	self.check(a.styles[Tool.MARKER.ordinal].size > old_size + 20, "dragging the slider grows the pen");
	self.check(a.ui.active == 0, "the slider lets go on release");
	self.check(b.items.len() == items, "dragging a slider draws nothing");
	self.drag({ slider_x + 80, slider_y }, { slider_x + 200, slider_y }, 3);
	self.check(a.styles[Tool.MARKER.ordinal].size <= ui::MAX_PEN_SIZE + 0.01f, "the slider stops at its end");
	a.styles[Tool.MARKER.ordinal].size = 16;

	// Colour picker, drawing with the colour it gives.
	self.click(self.swatch_at(12));
	self.check(a.ui.picker_open, "the colour button opens the picker");
	RLRectangle picker = a.ui.picker;
	float strip_y = picker.y + 12 + 132 + 12 + 8;
	self.click({ picker.x + 12 + (picker.width - 24) * 0.33f, strip_y }); // green hue
	self.click({ picker.x + picker.width - 16, picker.y + 18 }); // saturated, bright
	Rgba picked = a.styles[Tool.MARKER.ordinal].color;
	self.check(picked.g > 200 && picked.r < 90 && picked.b < 120, "the picker gives the colour shown");
	self.move_to({ picker.x + 100, picker.y + 100 });
	self.shot("17-picker.png");
	@pool()
	{
		// The square has to look like what it gives: white top left, the pure hue on
		// the right at the top, black along the whole bottom edge.
		String shot = self.file("17-picker.png");
		int left = (int)picker.x + 15;
		int right = (int)(picker.x + picker.width) - 15;
		int top = (int)picker.y + 15;
		int bottom = (int)picker.y + 12 + 132 - 3;
		RLColor white = pixel(shot, left, top);
		RLColor bottom_left = pixel(shot, left, bottom);
		RLColor bottom_right = pixel(shot, right, bottom);
		RLColor right_middle = pixel(shot, right, (top + bottom) / 2);
		self.check(white.r > 235 && white.g > 235 && white.b > 235, "the picker is white at the top left");
		self.check(bottom_left.g < 30 && bottom_right.g < 30, "the picker is black along the bottom");
		self.check(right_middle.g > 100 && right_middle.r < 60, "the picker shows the hue on the right");
	};
	self.check(b.items.len() == items, "the picker draws nothing");
	self.click(self.rail_button(PEN));
	self.check(!a.ui.picker_open, "changing tool closes the picker");

	// One undo step for a whole picker drag over a selected stroke.
	a.tool = PEN;
	self.scribble((Vec2[]){ { 200, 300 }, { 300, 330 } });
	uint stroke_id = self.top().id;
	a.tool = SELECT;
	a.selection.clear();
	a.selection.push(stroke_id);
	self.step();
	// With a selection, four action buttons come before the swatches.
	float first_swatch = a.ui.bar.x + 12 + 4 * ui::BUTTON + 14;
	self.click({ first_swatch + ui::SWATCH * 4.5f, a.ui.bar.y + 26 });
	self.check(b.get(stroke_id)!!.color.xyz == ui::INK_COLORS[4].xyz, "a swatch recolours the selection");
	sz steps = b.undo_steps.len();
	self.click({ a.ui.bar.x + 12 + 4 * ui::BUTTON + 14 + ui::SWATCH * 12.5f, a.ui.bar.y + 26 });
	self.check(a.ui.picker_open, "the picker opens for a selection");
	picker = a.ui.picker;
	self.drag({ picker.x + 30, picker.y + 30 }, { picker.x + 170, picker.y + 110 }, 12);
	self.check(b.undo_steps.len() == steps + 1, "a picker drag is one undo step");
	a.ui.picker_open = false;

	// Selection bar: delete button.
	self.step();
	self.click({ a.ui.bar.x + 12 + ui::BUTTON * 3.5f, a.ui.bar.y + 26 });
	self.check(!b.by_id.has_key(stroke_id), "the trash button deletes the selection");

	// Undo button in the top bar brings it back.
	RLRectangle top = a.ui.top;
	self.click({ top.x + 6 + ui::BUTTON * 0.5f, top.y + 5 + ui::BUTTON * 0.5f });
	self.check(b.by_id.has_key(stroke_id), "the undo button works");
	a.undo(); // recolour
	a.undo(); // recolour
	a.undo(); // the stroke
	self.step();
	self.check(b.items.len() == items, "back to where the test began");

	// Zoom buttons and the percentage.
	a.tool = SELECT;
	float zoom_label = top.x + 6 + ui::BUTTON * 2 + 6 + ui::BUTTON + 27;
	self.click({ zoom_label + 27 + ui::BUTTON * 0.5f, top.y + 25 });
	self.settle_camera();
	self.near(a.tab.cam.zoom, 1.4, "plus zooms in");
	self.click({ zoom_label, top.y + 25 });
	self.settle_camera();
	self.near(a.tab.cam.zoom, 1.0, "the percentage goes back to 100%");

	// Paper menu.
	float paper_x = top.x + 6 + ui::BUTTON * 2 + 6 + ui::BUTTON + 54 + ui::BUTTON * 2 + 6;
	self.click({ paper_x + ui::BUTTON * 0.5f, top.y + 25 });
	self.check(a.ui.paper_open, "the paper button opens its menu");
	RLRectangle menu = a.ui.paper_menu;
	self.click({ menu.x + 28 + 34 * 2, menu.y + 46 });
	self.check(a.tab.paper == 2, "a paper swatch changes the paper");
	self.click({ menu.x + 12 + 60 + 28, menu.y + 86 });
	self.check(a.tab.pattern == 1, "a pattern button changes the pattern");
	self.move_to({ menu.x + 100, menu.y + 90 });
	self.shot("18-dark-paper.png");
	self.click({ paper_x + ui::BUTTON * 0.5f, top.y + 25 });
	self.check(!a.ui.paper_open, "and it closes again");
	a.tab.paper = 0;
	a.tab.pattern = 0;

	// Help.
	Input* in = &a.input;
	in.first_press[(int)RLKeyboardKey.F1] = true;
	self.step();
	self.check(a.help_open, "F1 opens the shortcuts");
	self.step();
	self.shot("19-help.png");
	sz before_help = b.items.len();
	a.tool = PEN;
	self.click({ 640, 400 });
	self.check(!a.help_open, "a click closes them");
	self.check(b.items.len() == before_help, "and does not draw");

	// Tooltip.
	a.tool = SELECT;
	self.move_to(self.rail_button(HIGHLIGHTER));
	self.step();
	self.shot("20-tooltip.png");
	self.move_to({ 700, 400 });
}

fn void Script.test_dialogs(&self)
{
	self.section("file dialogs");
	App* a = self.a;
	if (!env::tget_var("E2E_FAKE_ZENITY") ?? false)
	{
		io::printn("  skipped: scripts/e2e.sh provides a stand-in for zenity");
		return;
	}
	int pictures = self.count(IMAGE);
	a.request_dialog(ADD_IMAGES);
	self.check(dialog::is_open(), "the dialog runs");
	for (int i = 0; i < 400 && dialog::is_open(); i++)
	{
		self.step();
		rl::wait_time(0.005);
	}
	self.step();
	self.check(!dialog::is_open(), "the dialog finishes without blocking the app");
	self.check(self.count(IMAGE) == pictures + 1, "the chosen picture is added");
}

fn void Script.test_tabs(&self)
{
	self.section("tabs");
	App* a = self.a;
	Tab* first = a.tab;
	sz first_items = first.board.items.len();
	PenStyle saved_pen = a.styles[Tool.PEN.ordinal];
	PenStyle* pen = &a.styles[Tool.PEN.ordinal];
	pen.size = 44;
	pen.opacity = 1;
	a.tool = PEN;

	String left_path = self.fresh("tab-left.tabla");
	a.new_board(left_path);
	Tab* left = a.tab;
	self.check(a.tab_count == 2 && left != first, "a new board opens in its own tab");
	self.check(left.board.items.is_empty(), "and starts empty");
	self.check(file::exists(left_path), "and exists on disk straight away");
	self.check(first.board.items.len() == first_items, "the first board stays loaded");
	a.new_board(self.fresh("tab-right.tabla"));
	Tab* right = a.tab;
	self.step();

	pen.color = { 30, 60, 230, 255 };
	self.scribble((Vec2[]){ { 500, 300 }, { 700, 300 } });
	self.click(self.tab_at(1));
	self.check(a.tab == left, "clicking a tab shows its board");
	self.check(self.count(INK) == 0, "the click does not draw on the board");
	pen.color = { 230, 40, 30, 255 };
	self.scribble((Vec2[]){ { 500, 300 }, { 700, 300 } });
	self.move_to({ 1000, 600 });
	self.shot("30-tab-left.png");
	@pool()
	{
		RLColor c = pixel(self.file("30-tab-left.png"), 600, 300);
		self.check(c.r > 180 && c.b < 90, "the shown tab draws its own ink");
	};
	self.ctrl_key(TAB);
	self.check(a.tab == right, "Ctrl+Tab goes to the next tab");
	self.shot("31-tab-right.png");
	@pool()
	{
		RLColor c = pixel(self.file("31-tab-right.png"), 600, 300);
		self.check(c.b > 180 && c.r < 90, "and nothing of the other board shows");
	};
	self.ctrl_key(TAB);
	self.check(a.tab == first, "the last tab wraps round to the first");
	self.ctrl_key(TAB, shift: true);
	self.check(a.tab == right, "Ctrl+Shift+Tab goes back");
	self.ctrl_key(PAGE_UP);
	self.check(a.tab == left, "Ctrl+PageUp goes back");
	self.ctrl_key(PAGE_DOWN);
	self.check(a.tab == right, "Ctrl+PageDown goes on");
	a.input.ctrl = true;
	self.tap(TAB); // only the repeat of a press, as an input method can send
	a.input.ctrl = false;
	self.check(a.tab == right, "a repeated key press does not change tabs");

	// Each tab keeps its own view and history.
	a.zoom_at({ 600, 300 }, 2);
	self.settle_camera();
	self.ctrl_key(PAGE_UP);
	self.near(a.tab.cam.zoom, 1, "a view does not leak into another tab");
	a.undo();
	self.check(self.count(INK) == 0, "undo works on the shown board");
	self.check(right.board.items.len() == 1, "and leaves the other board alone");
	a.redo();
	self.ctrl_key(PAGE_DOWN);
	self.near(a.tab.cam.zoom, 2, "a tab comes back as it was left");
	a.reset_view();

	// Nothing that is under way gets lost or lands on the wrong board.
	self.move_to({ 400, 420 });
	self.press();
	self.move_to({ 450, 440 });
	self.ctrl_key(TAB);
	self.check(a.tab == right, "tabs do not change in the middle of a stroke");
	self.release();
	self.check(self.count(INK) == 2, "and the stroke ends where it began");
	a.tool = TEXT;
	self.click({ 300, 520 });
	self.type("kept");
	self.check(a.edit_id != 0, "typing is under way");
	self.ctrl_key(PAGE_UP);
	self.check(a.edit_id == 0 && a.tab == left, "switching tabs finishes the text");
	self.check(right.board.items.len() == 3, "and the text stays on its own board");
	self.check(left.board.pending.is_empty() && right.board.pending.is_empty(), "no change is left half made");
	a.tool = PEN;

	// A tab that is out of sight still gets saved.
	self.scribble((Vec2[]){ { 500, 500 }, { 700, 500 } });
	self.check(left.has_unsaved(), "new ink waits for autosave");
	self.ctrl_key(PAGE_DOWN);
	self.check(left.has_unsaved(), "leaving the tab does not delay the switch with a save");
	for (int i = 0; i < 90; i++) self.step();
	self.check(!left.has_unsaved(), "a hidden tab autosaves");
	self.check(self.saved_items(left.path) == 2, "and its file has the ink");

	// Five is the limit.
	a.new_board(self.fresh("tab-c.tabla"));
	Tab* third = a.tab;
	a.new_board(self.fresh("tab-d.tabla"));
	self.step();
	self.check(a.tab_count == app::MAX_TABS, "five tabs can be open");
	String extra = self.fresh("tab-extra.tabla");
	a.new_board(extra);
	self.check(a.tab_count == app::MAX_TABS && !file::exists(extra), "a sixth new board is refused");
	self.check(a.toast_text.contains("Close one first"), "and the app says why");
	file::save(extra, "")!!;
	self.check(!a.open(extra), "a sixth open board is refused");
	a.request_dialog(NEW_BOARD);
	self.check(!dialog::is_open(), "no dialog opens for a board that would not fit");
	self.move_to(self.tab_at(4));
	self.shot("32-five-tabs.png");

	// A file has only one tab, however its path is spelled.
	self.check(a.open(left_path) && a.tab == left, "opening an open board shows its tab");
	a.show_tab(right);
	String dotted = string::format(mem, "%s/./tab-left.tabla", self.dir);
	self.check(a.open(dotted) && a.tab == left, "another spelling of the path finds it too");
	a.show_tab(right);
	String link = self.fresh("tab-link.tabla");
	@pool()
	{
		self.check(c_symlink(left_path.zstr_tcopy(), link.zstr_tcopy()) == 0, "making a symbolic link");
	};
	self.check(a.open(link) && a.tab == left, "and so does a symbolic link");
	self.check(a.tab_count == app::MAX_TABS, "none of that made a new tab");

	// Saving over a board that is open would lose it.
	a.show_tab(right);
	a.new_board(left_path);
	self.check(a.tab == left && left.board.items.len() == 2, "a new board cannot replace an open one");
	self.check(self.saved_items(left_path) == 2, "and that board's file is kept");
	a.save_as(right.path);
	self.check(a.tab.path == left_path, "save as cannot take over another tab's file");
	self.check(self.saved_items(right.path) == 3, "and the other tab's file is kept");

	// Closing.
	Tab* last = a.tabs[4];
	a.show_tab(last);
	self.letter('w', ctrl: true);
	self.check(a.tab_count == 4 && a.tab == a.tabs[3], "Ctrl+W closes the tab and shows its neighbour");
	Input* in = &a.input;
	in.ctrl = true;
	in.letters['w' - 'a'] = true;
	self.step();
	in.ctrl = false;
	self.check(a.tab_count == 4, "a held Ctrl+W closes only one tab");
	a.show_tab(left);
	self.step();
	self.move_to(self.tab_cross(a.tab_index(third)));
	self.click(self.tab_cross(a.tab_index(third)));
	self.check(a.tab_count == 3 && a.tab == left, "the cross closes a hidden tab and stays put");
	self.click(self.tab_cross(a.tab_index(left)));
	self.check(a.tab_count == 2 && a.tab == right, "the cross on the shown tab shows the next");
	self.check(self.saved_items(left_path) == 2, "a closed board is on disk");
	self.check(a.close_tab(right) && a.tab == first, "the first board is back");
	self.check(first.board.items.len() == first_items, "with everything it had");
	self.check(!a.close_tab(first), "the last tab stays open");
	a.toast_text = "";
	self.step();
	self.click(self.tab_cross(0));
	self.check(a.tab_count == 1 && !a.toast_text.len, "and has no cross to click");
	a.styles[Tool.PEN.ordinal] = saved_pen;
}

fn void Script.test_copy_between_tabs(&self)
{
	self.section("copying between tabs");
	App* a = self.a;
	Tab* first = a.tab;
	String picture = self.file("tab-photo.png");
	@pool()
	{
		make_test_picture(picture.zstr_tcopy(), { 220, 40, 40, 255 });
	};
	a.new_board(self.fresh("tab-target.tabla"));
	Tab* target = a.tab;
	a.new_board(self.fresh("tab-source.tabla"));
	Tab* source = a.tab;
	self.step();
	String[1] files = { picture };
	a.add_files(&files, { 640, 400 });
	self.step();
	Item* photo = self.top();
	self.check(photo.kind == IMAGE, "the picture is on the source board");
	a.tool = PEN;
	self.scribble((Vec2[]){ { 620, 400 }, { 660, 400 } });
	self.check(self.top().parent == photo.id, "with ink pinned to it");
	a.tool = SELECT;
	a.selection.clear();
	a.selection.push(photo.id);
	a.copy();
	self.check(a.close_tab(source), "the source tab can close after copying");
	self.check(a.tab == target, "leaving the other tab on screen");
	self.step();

	a.place_copies(&a.clip_items, { 640, 400 });
	self.check(self.count(IMAGE) == 1 && self.count(INK) == 1, "the paste arrives on another board");
	self.check(target.board.assets.len() == 1, "and that board has the picture itself");
	Item* pasted = a.tab.board.get(a.selection[0])!!;
	foreach (item : a.tab.board.items)
	{
		if (item.kind == INK) self.check(item.parent == pasted.id, "pinned ink follows it");
	}
	a.tool = PEN;
	self.step();
	self.step();
	self.check(pasted.asset.state == READY, "and the picture loads");
	self.move_to({ 1000, 700 });
	self.shot("33-pasted-between-tabs.png");
	@pool()
	{
		Vec2 sky = a.tab.cam.to_screen(pasted.pos + (DVec2){ 40.0, 20.0 } * pasted.scale);
		RLColor c = pixel(self.file("33-pasted-between-tabs.png"), (int)sky.x, (int)sky.y);
		self.check(c.r > 170 && c.b < 110, "with its real colours");
	};
	a.place_copies(&a.clip_items, { 300, 300 });
	self.check(target.board.assets.len() == 1, "pasting twice stores the picture once");
	self.check(a.save_now(true), "saving the pasted picture");
	Board check;
	check.init();
	(void)store::load(&check, target.path);
	self.check(check.assets.len() == 1 && check.assets[0].bytes.len > 0, "the picture is in the file");
	check.free();
	a.tool = PEN;
	self.check(a.close_tab(target) && a.tab == first, "back to the first board");
	a.clear_clip();
}

fn void Script.test_dialogs_and_tabs(&self)
{
	self.section("dialogs and tabs");
	App* a = self.a;
	if (!env::tget_var("E2E_FAKE_ZENITY") ?? false)
	{
		io::printn("  skipped: scripts/e2e.sh provides a stand-in for zenity");
		return;
	}
	Tab* first = a.tab;
	a.new_board(self.fresh("tab-asking.tabla"));
	Tab* asking = a.tab;
	a.new_board(self.fresh("tab-other.tabla"));
	Tab* other = a.tab;

	a.show_tab(asking);
	a.request_dialog(ADD_IMAGES);
	a.show_tab(other); // a board dropped on the window can do this while the dialog is up
	self.wait_for_dialog();
	self.check(asking.board.assets.len() == 1, "a dialog's answer goes to the tab that asked");
	self.check(other.board.assets.is_empty(), "not to the tab that happens to be on screen");
	self.check(a.tab == asking, "and that tab is shown");

	a.show_tab(other);
	self.step();
	a.request_dialog(ADD_IMAGES);
	self.check(a.close_tab(other), "closing the tab that asked");
	self.wait_for_dialog();
	self.check(a.toast_text.contains("closed"), "an answer for a closed tab is reported");
	self.check(asking.board.assets.len() == 1, "and goes nowhere else");

	// An answer that arrives during a stroke waits for the stroke to end.
	int pictures = self.count(IMAGE);
	a.tool = PEN;
	self.move_to({ 500, 300 });
	self.press();
	self.move_to({ 560, 320 });
	a.request_dialog(ADD_IMAGES);
	for (int i = 0; i < 400 && dialog::is_open(); i++)
	{
		self.step();
		rl::wait_time(0.005);
	}
	self.step();
	self.check(a.mode == INKING && self.count(IMAGE) == pictures, "a dialog's answer waits for the pointer");
	self.release();
	self.step();
	self.check(self.count(INK) == 1, "the stroke is finished");
	self.check(self.count(IMAGE) == pictures + 1, "and then the answer is applied");
	self.check(a.close_tab(asking) && a.tab == first, "back to the first board");
}

fn void Script.test_failed_saves(&self)
{
	self.section("boards that cannot be saved");
	App* a = self.a;
	Tab* first = a.tab;
	a.tool = PEN;
	// A regular file in the middle of a path makes every save there fail, even for root.
	String wall = self.file("tab-wall");
	file::save(wall, "not a directory")!!;
	String blocked = string::format(mem, "%s/inside.tabla", wall);

	sz tabs = a.tab_count;
	a.new_board(blocked);
	self.check(a.tab_count == tabs, "a new board that cannot be written does not open");
	self.check(a.toast_text.contains("Could not create"), "and the app says so");

	String good = self.fresh("tab-failing.tabla");
	a.new_board(good);
	Tab* failing = a.tab;
	self.step();
	self.scribble((Vec2[]){ { 500, 300 }, { 700, 300 } });

	// The file's folder disappears, as a removable disk's would.
	free(failing.path);
	failing.path = blocked.copy(mem);
	self.check(!a.close_tab(failing), "a tab that cannot save refuses to close");
	self.check(a.tab == failing && self.count(INK) == 1, "and its board is intact");
	self.check(failing.save_failed, "the tab shows that it failed");
	self.check(a.toast_text.contains("stays open"), "and the app says what happened");
	self.letter('w', ctrl: true);
	self.check(a.tab_count == tabs + 1, "Ctrl+W is held back in the same way");
	self.move_to({ 1000, 600 });
	self.shot("34-failed-save.png");

	// Opening another board used to close this one regardless.
	String next = self.fresh("tab-next.tabla");
	a.new_board(next);
	self.check(a.tab_count == tabs + 2, "opening another board keeps it");
	self.check(failing.board.items.len() == 1, "with its work");

	a.input.time += 1;
	a.quit_confirm_until = 0;
	a.request_quit();
	self.check(!a.quit, "quitting is held back while a board cannot be saved");
	self.check(a.toast_text.contains("again"), "and the app says how to go on");
	a.input.time += app::QUIT_CONFIRM_SECONDS + 1;
	a.request_quit();
	self.check(!a.quit, "a much later close is a first close again");
	a.request_quit();
	self.check(a.quit, "a second close is the user's decision");
	a.quit = false;

	// Hidden or not, it keeps trying, and recovers as soon as the file is back.
	free(failing.path);
	failing.path = good.copy(mem);
	self.check(failing.has_unsaved(), "the board is still waiting to be saved");
	self.step();
	a.input.time += app::AUTOSAVE_RETRY + 1;
	self.step();
	self.check(!failing.has_unsaved() && !failing.save_failed, "a hidden tab retries and recovers");
	self.check(self.saved_items(good) == 1, "and the work reaches the file");
	self.check(a.close_tab(a.tab), "closing the other tab");

	// Save as must not abandon a file that works for one that does not.
	a.show_tab(failing);
	self.scribble((Vec2[]){ { 500, 400 }, { 700, 400 } });
	a.save_as(blocked);
	self.check(a.tab == failing && failing.path == good, "a failed save as keeps the old file");
	self.check(a.toast_text.contains("Could not save"), "and says so");
	for (int i = 0; i < 90; i++) self.step();
	self.check(self.saved_items(good) == 2, "and autosave carries on there");
	String moved = self.fresh("tab-moved.tabla");
	a.save_as(moved);
	self.check(failing.path == moved && self.saved_items(moved) == 2, "a working save as moves the board");
	self.check(a.close_tab(failing) && a.tab == first, "back to the first board");
	a.quit_confirm_until = 0;
}

fn long Script.texture_bytes(&self)
{
	long used = 0;
	foreach (tab : self.a.open_tabs())
	{
		foreach (asset : tab.board.assets)
		{
			if (asset.state == READY) used += asset.texture_bytes;
		}
	}
	return used;
}

fn int count_ready(Tab* tab) @local
{
	int ready = 0;
	foreach (asset : tab.board.assets)
	{
		if (asset.state == READY) ready++;
	}
	return ready;
}

fn void Script.test_photo_limit(&self)
{
	self.section("photo memory limit");
	App* a = self.a;
	Tab* first = a.tab;
	a.tool = SELECT;
	long one = (long)640 * 420 * 4 * 4 / 3;
	RLColor[*] skies = { { 220, 40, 40, 255 }, { 40, 200, 60, 255 }, { 40, 60, 220, 255 }, { 220, 200, 40, 255 }, { 40, 200, 220, 255 } };
	String[5] files;
	foreach (i, sky : skies)
	{
		files[i] = self.file(string::tformat("limit-%d.png", i));
		@pool()
		{
			make_test_picture(files[i].zstr_tcopy(), sky);
		};
	}
	a.show_tab(first);
	foreach (asset : first.board.assets)
	{
		if (asset.state == READY) render::drop_texture(asset);
	}
	a.tab.cam = { .origin = { 1e7, 1e7 }, .zoom = 1 }; // the first board's pictures are out of view
	a.tab.cam_target = a.tab.cam;
	self.step();
	a.gfx.texture_budget = one * 2 + 1000;

	a.new_board(self.fresh("limit-gallery.tabla"));
	Tab* gallery = a.tab;
	self.step();
	Vec2[3] spots = { { 330, 240 }, { 900, 240 }, { 620, 590 } };
	foreach (i, spot : spots)
	{
		String[1] file_name = { files[i] };
		a.add_files(&file_name, spot);
	}
	a.selection.clear();
	foreach (item : a.tab.board.items) a.tab.board.touch(item).scale = 0.6;
	a.tab.board.commit();
	a.fit_all();
	self.settle_camera();
	for (int i = 0; i < 5; i++) self.step();
	self.check(gallery.board.assets.len() == 3, "three pictures on one board");
	self.check(count_ready(gallery) == 3, "pictures on screen stay, even over the limit");

	a.new_board(self.fresh("limit-other.tabla"));
	Tab* other = a.tab;
	self.step();
	foreach (i, spot : (Vec2[]){ { 330, 400 }, { 900, 400 } })
	{
		String[1] file_name = { files[3 + i] };
		a.add_files(&file_name, spot);
	}
	a.selection.clear();
	self.step();
	self.step();
	self.check(count_ready(other) == 2, "the tab on screen has its pictures");
	self.check(count_ready(gallery) == 0, "the hidden tab has given up its textures");
	self.check(self.texture_bytes() <= a.gfx.texture_budget, "and memory is back within the limit");

	// Going back loads them again, and the app must not go idle half way through: with
	// no input coming, the remaining pictures would stay grey until the mouse moved.
	for (int i = 0; i < 300; i++) self.step();
	self.check(!a.busy(), "nothing else is keeping the app awake");
	a.show_tab(gallery);
	self.step();
	self.check(count_ready(gallery) == 1, "pictures come back one per frame");
	self.check(a.busy(), "the app keeps working while pictures are missing");
	self.step();
	self.check(a.busy(), "and still does with one to go");
	self.step();
	self.check(count_ready(gallery) == 3, "all of them return");
	self.check(!a.busy(), "and then the app can rest");
	self.check(count_ready(other) == 0, "at the cost of the tab now hidden");
	self.move_to({ 1250, 780 });
	self.shot("35-photos-after-limit.png");
	@pool()
	{
		foreach (i, item : gallery.board.items)
		{
			Vec2 p = a.tab.cam.to_screen(item.pos + (DVec2){ 30.0, 12.0 } * item.scale);
			RLColor c = pixel(self.file("35-photos-after-limit.png"), (int)p.x, (int)p.y);
			RLColor want = skies[i];
			bool close = math::abs((int)c.r - want.r) < 70 && math::abs((int)c.g - want.g) < 70 && math::abs((int)c.b - want.b) < 70;
			self.check(close, "a reloaded picture shows its own pixels");
		}
	};

	// Within a tab too: the one drawn longest ago goes first.
	a.tab.cam = { .origin = { 1e7, 1e7 }, .zoom = 1 };
	a.tab.cam_target = a.tab.cam;
	foreach (asset : gallery.board.assets)
	{
		if (asset.state == READY) render::drop_texture(asset);
	}
	Item*[3] pictures = { gallery.board.items[0], gallery.board.items[1], gallery.board.items[2] };
	foreach (item : pictures)
	{
		a.fit_view(item.bounds());
		a.tab.cam = a.tab.cam_target;
		self.step();
		self.step();
		self.check(item.asset.state == READY, "the picture in view is loaded");
	}
	self.check(pictures[0].asset.state == UNLOADED, "the least recently seen picture goes first");
	self.check(pictures[1].asset.state == READY, "and the more recent one stays");

	// Dropped textures cost nothing that matters: the bytes are still there.
	Asset* dropped = pictures[0].asset;
	self.check(dropped.bytes.len > 0, "the picture's file stays in memory");
	self.check(a.save_now(true), "a board with dropped textures saves");
	Board check;
	check.init();
	(void)store::load(&check, gallery.path);
	self.check(check.assets.len() == 3, "with every picture in it");
	check.free();
	a.selection.clear();
	a.tab.board.bring_to_front(pictures[0]);
	a.tab.board.commit();
	a.undo();
	self.check(gallery.board.items.len() == 3, "undo does not need the texture");

	// Export wants every picture at once, and is allowed to, but only for a moment.
	String png = self.fresh("limit-export.png");
	a.export_board(png);
	self.check(file::exists(png), "a board over the limit exports");
	self.step();
	self.check(self.texture_bytes() <= a.gfx.texture_budget, "and memory comes back down afterwards");
	@pool()
	{
		RLImage image = rl::load_image(png.zstr_tcopy());
		self.check(image.width > 100, "the export has content");
		rl::unload_image(image);
	};

	a.gfx.texture_budget = render::TEXTURE_BUDGET;
	self.check(a.close_tab(other), "closing the test tabs");
	self.check(a.close_tab(gallery) && a.tab == first, "back to the first board");
}

fn void Script.test_tab_names(&self)
{
	self.section("tab names in a narrow window");
	App* a = self.a;
	Tab* first = a.tab;
	int width = rl::get_screen_width();
	int height = rl::get_screen_height();
	rl::set_window_size(860, 670);
	for (int i = 0; i < 30 && rl::get_screen_width() != 860; i++)
	{
		self.step();
		rl::wait_time(0.02);
	}
	self.check(rl::get_screen_width() == 860, "the window can get this small");
	String[4] names = { "šđčćž-plan-za-veliku-tablu.tabla", "short.tabla", "ideas-and-other-long-names-that-go-on.tabla", "čć.tabla" };
	foreach (name : names) a.new_board(self.fresh(name));
	self.check(a.tab_count == app::MAX_TABS, "five tabs");
	self.move_to({ 500, 400 });
	self.step();
	self.shot("36-narrow-tabs.png");
	self.check(a.ui.tab_strip.x + a.ui.tab_strip.width <= a.ui.top.x, "the tabs stop short of the toolbar");
	self.check(a.ui.rail.y >= a.ui.tab_strip.y + a.ui.tab_strip.height, "and clear of the tool rail");
	self.check(a.ui.rail.y + a.ui.rail.height <= rl::get_screen_height(), "and the rail still fits");
	foreach (tab : a.open_tabs()) tab.board.commit();
	while (a.tab_count > 1) self.check(a.close_tab(a.tab), "closing a test tab");
	self.check(a.tab == first, "back to the first board");
	rl::set_window_size(width, height);
	for (int i = 0; i < 30 && rl::get_screen_width() != width; i++)
	{
		self.step();
		rl::wait_time(0.02);
	}
}

fn void Script.test_clipboard(&self)
{
	self.section("clipboard picture");
	App* a = self.a;
	clip::Content content = clip::read(rl::get_window_handle(), "TABLA_TEST_SELECTION");
	defer content.free();
	if (content.kind == NOTHING)
	{
		io::printn("  skipped: run scripts/e2e.sh for this part");
		return;
	}
	self.check(content.kind == PICTURE, "the test owner offers a picture");
	self.check(content.extension == ".png", "PNG is preferred");
	io::printfn("  received %d bytes", content.bytes.len());
	int pictures = self.count(IMAGE);
	a.paste_content(&content, { 640, 400 });
	self.step();
	self.check(self.count(IMAGE) == pictures + 1, "pasted picture lands on the board");
}

fn int run_e2e(String dir)
{
	rl::set_trace_log_level(ERROR);
	rl::set_config_flags(RLConfigFlag.MSAA_4X_HINT | RLConfigFlag.WINDOW_HIDDEN);
	rl::init_window(1280, 800, "Tabla e2e");
	App* a = mem::new(App);
	a.scripted = true;
	String board_path = string::format(mem, "%s/e2e.tabla", dir);
	(void)file::delete(board_path);
	a.init(board_path);
	a.input.time = 100; // past every startup timer
	Script s = { .a = a, .dir = dir };
	s.step();
	s.shot("00-empty.png");
	s.test_pens();
	s.test_undo_of_everything();
	s.test_shapes();
	s.test_pictures();
	s.test_eraser();
	s.test_text();
	s.test_zoom();
	s.test_copy_paste();
	s.test_save_and_load();
	s.test_export();
	s.test_long_messages();
	s.test_picture_files();
	s.test_recovery();
	s.test_ui();
	s.test_dialogs();
	s.test_clipboard();
	s.test_tabs();
	s.test_copy_between_tabs();
	s.test_dialogs_and_tabs();
	s.test_failed_saves();
	s.test_photo_limit();
	s.test_tab_names();
	a.shutdown();
	rl::close_window();
	io::printfn("%d checks, %d failed", s.checks, s.failures);
	return s.failures ? 1 : 0;
}

fn double Script.time_frames(&self, int frames)
{
	double start = rl::get_time();
	for (int i = 0; i < frames; i++) self.step();
	return (rl::get_time() - start) * 1000 / frames;
}

fn int run_perf(String dir, int strokes)
{
	rl::set_trace_log_level(ERROR);
	rl::set_config_flags(RLConfigFlag.MSAA_4X_HINT | RLConfigFlag.WINDOW_HIDDEN);
	rl::init_window(1280, 800, "Tabla perf");
	App* a = mem::new(App);
	a.scripted = true;
	String path = string::format(mem, "%s/perf.tabla", dir);
	(void)file::delete(path);
	a.init(path);
	a.input.time = 100;
	Script s = { .a = a, .dir = dir };
	Board* b = &a.tab.board;

	const int POINTS = 80;
	double t = rl::get_time();
	for (int i = 0; i < strokes; i++)
	{
		InkPoint[] points = mem::new_array(InkPoint, POINTS);
		for (int p = 0; p < POINTS; p++)
		{
			points[p] = { p * 3.0f, math::sin(p * 0.3f + i) * 20, 3 };
		}
		DVec2 pos = { (double)(i % 200) * 280.0, (double)(i / 200) * 60.0 };
		b.add({ .kind = INK, .pos = pos, .scale = 1, .color = { 26, 26, 30, i % 4 ? 255 : 150 }, .ink = board::ink_new(points, true, ROUND) });
	}
	b.commit();
	io::printfn("%d strokes, %d points each", strokes, POINTS);
	io::printfn("build board           %8.1f ms", (rl::get_time() - t) * 1000);

	a.fit_all();
	a.tab.cam = a.tab.cam_target;
	t = rl::get_time();
	s.step();
	io::printfn("first frame (meshes)  %8.1f ms", (rl::get_time() - t) * 1000);
	io::printfn("frame, all visible    %8.2f ms", s.time_frames(60));

	a.tab.cam = { .origin = { 0, 0 }, .zoom = 1 };
	a.tab.cam_target = a.tab.cam;
	s.step();
	io::printfn("frame, zoomed in      %8.2f ms", s.time_frames(60));
	a.tool = SELECT;
	io::printfn("frame, select hover   %8.2f ms", s.time_frames(60));

	// The action that happens all day: finish one stroke on a full board.
	a.tool = PEN;
	t = rl::get_time();
	for (int i = 0; i < 20; i++)
	{
		Vec2[2] line = { { 200, 200 + (float)i * 2 }, { 240, 210 } };
		s.scribble(&line);
	}
	double per = (rl::get_time() - t) * 1000 / 20;
	io::printfn("one stroke, start-end %8.1f ms (9 frames)", per);

	t = rl::get_time();
	Item copy = *b.items[0];
	copy.retain();
	copy.id = 0;
	copy.z = 0;
	b.add(copy);
	b.commit();
	io::printfn("add and commit        %8.2f ms", (rl::get_time() - t) * 1000);

	t = rl::get_time();
	a.undo();
	io::printfn("undo                  %8.2f ms", (rl::get_time() - t) * 1000);
	t = rl::get_time();
	a.redo();
	io::printfn("redo                  %8.2f ms", (rl::get_time() - t) * 1000);

	a.tool = SELECT;
	foreach (item : b.items) a.selection.push(item.id);
	io::printfn("frame, all selected   %8.2f ms", s.time_frames(30));
	t = rl::get_time();
	a.bring_to_front();
	io::printfn("raise all to front    %8.1f ms", (rl::get_time() - t) * 1000);
	a.selection.clear();

	// Screen (100, 100) is left of everything, so this drag starts on empty canvas.
	a.tab.cam = a.tab.cam_target = { .origin = { -3000, -3000 }, .zoom = 0.05 };
	s.step();
	t = rl::get_time();
	s.drag({ 100, 100 }, { 1200, 780 }, 4);
	io::printfn("marquee over all      %8.1f ms (6 frames), %d selected", (rl::get_time() - t) * 1000, a.selection.len());
	a.selection.clear();

	t = rl::get_time();
	a.save_now(true);
	io::printfn("save                  %8.1f ms, %d KB", (rl::get_time() - t) * 1000, (file::get_size(path) ?? 0) / 1024);
	t = rl::get_time();
	Board loaded;
	loaded.init();
	(void)store::load(&loaded, path);
	io::printfn("load                  %8.1f ms", (rl::get_time() - t) * 1000);
	loaded.free();

	// The other tabs stay loaded, so going back to this board is one ordinary frame.
	String other = string::format(mem, "%s/perf-tab.tabla", dir);
	(void)file::delete(other);
	a.new_board(other);
	t = rl::get_time();
	for (int i = 0; i < 20; i++)
	{
		a.cycle_tab(1);
		s.step();
	}
	io::printfn("switch tab and draw   %8.2f ms", (rl::get_time() - t) * 1000 / 20);
	a.shutdown();
	rl::close_window();
	return 0;
}
