// The application: tools, pointer handling, editing commands and file handling.
module tabla::app;
import tabla::board, tabla::geom, tabla::render, tabla::input, tabla::store, tabla::clip, tabla::dialog, tabla::ui;
import raylib55::rl;
import std::io, std::math, std::collections::list, std::collections::map, std::hash::fnv64a, std::core::string::conv;

const double MIN_ZOOM = 1e-5;
const double MAX_ZOOM = 1e5;
const double DOUBLE_CLICK_SECONDS = 0.35;
const float DRAG_THRESHOLD = 3;
const float HANDLE_REACH = 11;
const float NOTE_SIZE = 240;
const double AUTOSAVE_DELAY = 1.0;
const double AUTOSAVE_RETRY = 30.0;
const double QUIT_CONFIRM_SECONDS = 10.0;
const String CLIP_MARKER = "tabla:board-items";
const int MAX_TABS = 5;

extern fn ZString c_realpath(ZString path, char* resolved) @cname("realpath");

enum Tool : char
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
}

fn bool Tool.is_ink(self) => self == PEN || self == BRUSH || self == MARKER || self == HIGHLIGHTER;
fn bool Tool.is_shape(self) => self == LINE || self == ARROW || self == RECT || self == ELLIPSE;
fn bool Tool.draws(self) => self.is_ink() || self.is_shape() || self == ERASER;

enum Mode : char
{
	IDLE,
	PANNING,
	INKING,
	SHAPING,
	ERASING,
	PRESSING, // left button down on a selected item, not yet a drag
	MOVING,
	RESIZING,
	MARQUEE,
}

struct PenStyle
{
	Rgba color;
	float size; // in screen pixels at the moment of drawing
	float opacity;
	float smoothing;
}

// The stroke or shape being made.
struct Capture
{
	List{InkPoint} points;
	DVec2 origin;
	Vec2 filtered;
	Vec2 raw;
	float follow;
	float base_width;
	float width;
	double last_time;
	bool speed_width;
	bool smooth;
	Tip tip;
	Rgba color;
	uint parent;
}

struct Pose
{
	uint id;
	DVec2 pos;
	double scale;
}

// One open board, with everything that belongs to it rather than to the window.
struct Tab
{
	uint serial; // never reused, so that a dialog can tell when its tab has closed
	Board board;
	Camera cam;
	Camera cam_target;
	char paper;
	char pattern;
	String path; // empty when the board has no file
	ulong saved_revision;
	bool view_dirty;
	bool save_failed;
	double last_change_time;
	double next_save_time;
	ulong seen_revision;
}

struct App
{
	Input input;
	Renderer gfx;
	Tab* tab; // the one on screen
	Tab*[MAX_TABS] tabs;
	int tab_count;
	uint last_serial;
	uint dialog_tab;

	Tool tool;
	PenStyle[Tool::len] styles;
	Mode mode;
	Capture capture;

	List{uint} selection;
	uint hover_id;
	Vec2 press_screen;
	DVec2 press_world;
	DVec2 last_erase;
	double last_press_time;
	Vec2 last_press_pos;
	List{Pose} poses;
	DRect resize_box;
	int resize_corner;
	DVec2 resize_anchor;

	uint edit_id;
	bool edit_is_new;
	List{char} edit_text;
	sz edit_caret;
	double caret_blink;

	List{Item} clip_items;
	Board clip_board; // owns copied pictures: the tab they came from can close before the paste

	Vec2 drop_offset;

	char[200] toast_buffer;
	String toast_text;
	double toast_until;

	bool quit;
	double quit_confirm_until;
	bool scripted; // driven by the end-to-end tests: never wait for real events
	bool cursor_hidden;
	bool help_open;
	Ui ui;

	String capture_path; // set by the end-to-end tests to grab the next frame
}

fn void App.toast(&self, String format, args...) => @pool()
{
	// Messages quote file paths, which can be any length.
	String text = string::tformat(format, ...args);
	sz length = math::min(text.len, (sz)self.toast_buffer.len);
	while (length > 0 && length < text.len && (text[length] & 0xC0) == 0x80) length--;
	self.toast_buffer[:length] = text[:length];
	self.toast_text = (String)self.toast_buffer[:length];
	self.toast_until = self.input.time + 3.5;
}

fn void App.set_default_styles(&self)
{
	self.styles[Tool.PEN.ordinal] = { { 26, 26, 30, 255 }, 3, 1, 0.35f };
	self.styles[Tool.BRUSH.ordinal] = { { 29, 111, 224, 255 }, 9, 1, 0.5f };
	self.styles[Tool.MARKER.ordinal] = { { 229, 56, 59, 255 }, 16, 0.92f, 0.35f };
	self.styles[Tool.HIGHLIGHTER.ordinal] = { { 252, 214, 40, 255 }, 30, 0.45f, 0.5f };
	self.styles[Tool.ERASER.ordinal] = { { 0, 0, 0, 255 }, 26, 1, 0 };
	foreach (shape : (Tool[]){ LINE, ARROW, RECT, ELLIPSE })
	{
		self.styles[shape.ordinal] = { { 26, 26, 30, 255 }, 3, 1, 0 };
	}
	self.styles[Tool.TEXT.ordinal] = { { 26, 26, 30, 255 }, 24, 1, 0 };
	self.styles[Tool.NOTE.ordinal] = { ui::NOTE_COLORS[0], 1, 1, 0 };
}

fn void App.reset_view(&self)
{
	self.tab.cam = { .origin = { 0, 0 }, .zoom = 1 };
	self.tab.cam_target = self.tab.cam;
}

fn void App.init(&self, String path)
{
	self.gfx.init();
	self.clip_board.init();
	self.selection.init(mem);
	self.poses.init(mem);
	self.edit_text.init(mem);
	self.clip_items.init(mem);
	self.capture.points.init(mem);
	self.set_default_styles();
	self.tool = PEN;
	self.input.width = rl::get_screen_width();
	self.input.height = rl::get_screen_height();
	self.open_or_create(path);
}

<*
 Shows the board in `path` in a tab, starting a new one if there is no such file yet.
*>
fn void App.open_or_create(&self, String path)
{
	if (try open = self.find_tab(path))
	{
		self.show_tab(open);
		return;
	}
	if (!self.has_room()) return;
	if (file::exists(path))
	{
		if (self.open(path)) return;
		// The file is damaged, and it stays as it is for the user to look at. New work
		// goes next to it, so that it is saved all the same.
		String fallback = path.tconcat(".recovered.tabla");
		if (file::exists(fallback) && self.open(fallback)) return;
		path = fallback;
	}
	Board next;
	next.init();
	self.add_tab(&next, { .zoom = 1 }, path);
}

fn void App.update_title(&self)
{
	@pool()
	{
		rl::set_window_title(string::tformat_zstr("%s - Tabla", self.tab.name()));
	};
}

fn void App.clear_clip(&self)
{
	foreach (&item : self.clip_items) item.release();
	self.clip_items.clear();
	self.clip_board.free();
	self.clip_board.init();
}

fn void App.shutdown(&self)
{
	self.settle();
	foreach (tab : self.open_tabs()) self.save_tab(tab, tab == self.tab);
	self.clear_clip();
	self.clip_items.free();
	self.clip_board.free();
	foreach (tab : self.open_tabs()) tab.free();
	self.gfx.free();
	self.selection.free();
	self.poses.free();
	self.edit_text.free();
	self.capture.points.free();
}

fn bool Tab.has_unsaved(&self) => self.path.len && self.board.revision != self.saved_revision;

fn store::View Tab.view(&self) => { .origin = self.cam.origin, .zoom = self.cam.zoom, .paper = self.paper, .pattern = self.pattern };

fn String Tab.name(&self)
{
	if (!self.path.len) return "Unsaved board";
	String name = self.path.file_tbasename() ?? self.path;
	return name.ends_with(".tabla") ? name[:name.len - 6] : name;
}

fn void Tab.free(&self)
{
	self.board.free();
	if (self.path.ptr) free(self.path.ptr);
	free(self);
}

fn Tab*[] App.open_tabs(&self) => self.tabs[:self.tab_count];

<*
 Writes a board to its file. Without `force`, a board with nothing new in it is left as
 it is.

 @return "whether the file now holds the board"
*>
fn bool App.save_tab(&self, Tab* tab, bool force = false)
{
	if (!tab.path.len) return false;
	if (!force && !tab.has_unsaved() && !tab.view_dirty) return true;
	if (catch excuse = store::save(&tab.board, tab.view(), tab.path))
	{
		self.toast("Could not save %s (%s)", tab.path, excuse);
		tab.save_failed = true;
		return false;
	}
	tab.saved_revision = tab.board.revision;
	tab.view_dirty = false;
	tab.save_failed = false;
	return true;
}

fn bool App.save_now(&self, bool force = false) => self.save_tab(self.tab, force);

// Tabs on screen or not, boards save themselves a moment after they last changed.
fn void App.autosave(&self)
{
	double now = self.input.time;
	foreach (tab : self.open_tabs())
	{
		if (tab.board.revision != tab.seen_revision)
		{
			tab.seen_revision = tab.board.revision;
			tab.last_change_time = now;
		}
		if (!tab.has_unsaved()) continue;
		if (tab == self.tab && (self.mode != IDLE || self.edit_id)) continue;
		if (now < tab.next_save_time || now - tab.last_change_time < AUTOSAVE_DELAY) continue;
		if (!self.save_tab(tab)) tab.next_save_time = now + AUTOSAVE_RETRY;
	}
}

<*
 Keeps picture textures within the budget by dropping the ones drawn longest ago, which
 are normally those in other tabs. Whatever is on screen stays, even over the budget.
*>
fn void App.limit_textures(&self)
{
	long used = 0;
	foreach (tab : self.open_tabs())
	{
		foreach (asset : tab.board.assets)
		{
			if (asset.state == READY) used += asset.texture_bytes;
		}
	}
	while (used > self.gfx.texture_budget)
	{
		Asset* oldest = null;
		foreach (tab : self.open_tabs())
		{
			foreach (asset : tab.board.assets)
			{
				if (asset.state != READY || asset.last_drawn == self.gfx.frame) continue;
				if (!oldest || asset.last_drawn < oldest.last_drawn) oldest = asset;
			}
		}
		if (!oldest) return;
		used -= oldest.texture_bytes;
		render::drop_texture(oldest);
	}
}

fn void App.forget_board_state(&self)
{
	self.selection.clear();
	self.hover_id = 0;
	self.mode = IDLE;
}

// Paths differ in many ways that lead to one file, and two tabs on one file would
// overwrite each other's work.
fn bool same_file(String a, String b) @local
{
	if (a == b) return true;
	char[4096] real_a;
	char[4096] real_b;
	@pool()
	{
		if (!c_realpath(a.zstr_tcopy(), &real_a) || !c_realpath(b.zstr_tcopy(), &real_b)) return false;
	};
	return ((ZString)&real_a).str_view() == ((ZString)&real_b).str_view();
}

excuse NOT_OPEN;

fn Tab*? App.find_tab(&self, String path)
{
	foreach (tab : self.open_tabs())
	{
		if (same_file(tab.path, path)) return tab;
	}
	return NOT_OPEN~;
}

fn int App.tab_index(&self, Tab* tab)
{
	foreach (i, known : self.open_tabs())
	{
		if (known == tab) return (int)i;
	}
	unreachable("not an open tab");
}

fn bool App.has_room(&self)
{
	if (self.tab_count < MAX_TABS) return true;
	self.toast("%d boards are open. Close one first.", MAX_TABS);
	return false;
}

fn void App.show_tab(&self, Tab* tab)
{
	if (tab == self.tab) return;
	if (self.tab) self.settle();
	self.forget_board_state();
	self.tab = tab;
	self.tab.board.sync();
	self.update_title();
}

fn void App.cycle_tab(&self, int step)
{
	self.show_tab(self.tabs[(self.tab_index(self.tab) + step + self.tab_count) % self.tab_count]);
}

// Takes ownership of `board` and shows it. The caller has checked that there is room.
fn void App.add_tab(&self, Board* board, store::View view, String path)
{
	Tab* tab = mem::new(Tab);
	tab.serial = ++self.last_serial;
	tab.board = *board;
	tab.cam = { .origin = view.origin, .zoom = math::clamp(view.zoom, MIN_ZOOM, MAX_ZOOM) };
	tab.cam_target = tab.cam;
	tab.paper = view.paper;
	tab.pattern = view.pattern;
	tab.path = path.copy(mem);
	tab.saved_revision = tab.board.revision;
	tab.seen_revision = tab.board.revision;
	self.tabs[self.tab_count++] = tab;
	self.show_tab(tab);
}

<*
 Closes a tab, unless that would lose work: a board that cannot be saved stays open.

 @return "whether the tab has closed"
*>
fn bool App.close_tab(&self, Tab* tab)
{
	if (self.tab_count == 1)
	{
		self.toast("This is the only open board");
		return false;
	}
	if (tab == self.tab) self.settle();
	if (!self.save_tab(tab))
	{
		@pool()
		{
			self.toast("Could not save %s, so it stays open", tab.name());
		};
		return false;
	}
	int index = self.tab_index(tab);
	if (tab == self.tab) self.show_tab(self.tabs[index + 1 < self.tab_count ? index + 1 : index - 1]);
	for (int i = index; i + 1 < self.tab_count; i++) self.tabs[i] = self.tabs[i + 1];
	self.tab_count--;
	tab.free();
	return true;
}

<*
 Quits once every board is on disk. If one cannot be saved the window stays, and only a
 second close soon after gives up that work.
*>
fn void App.request_quit(&self)
{
	self.settle();
	bool saved = true;
	foreach (tab : self.open_tabs())
	{
		if (!self.save_tab(tab)) saved = false;
	}
	if (saved || self.input.time < self.quit_confirm_until)
	{
		self.quit = true;
		return;
	}
	self.quit_confirm_until = self.input.time + QUIT_CONFIRM_SECONDS;
	self.toast("Some boards could not be saved. Close the window again to quit anyway.");
}

<*
 Shows the board in `path`, in a new tab unless it is already open. A file that cannot
 be read is left alone: autosave must never replace a board that merely failed to load.

 @return "whether the board is now on screen"
*>
fn bool App.open(&self, String path)
{
	if (try open = self.find_tab(path))
	{
		self.show_tab(open);
		return true;
	}
	if (!self.has_room()) return false;
	Board next;
	next.init();
	store::View? view = store::load(&next, path);
	if (catch excuse = view)
	{
		next.free();
		self.toast("Could not open %s (%s)", path, excuse);
		return false;
	}
	self.add_tab(&next, view, path);
	return true;
}

fn void App.new_board(&self, String path)
{
	if (try open = self.find_tab(path))
	{
		self.toast("That board is already open");
		self.show_tab(open);
		return;
	}
	if (!self.has_room()) return;
	Board next;
	next.init();
	store::View view = { .zoom = 1, .paper = self.tab.paper, .pattern = self.tab.pattern };
	if (catch excuse = store::save(&next, view, path))
	{
		next.free();
		self.toast("Could not create %s (%s)", path, excuse);
		return;
	}
	self.add_tab(&next, view, path);
}

<*
 Moves the board to `path`. Until that has worked the board keeps its old file, which
 autosave can still reach.
*>
fn void App.save_as(&self, String path)
{
	if (try open = self.find_tab(path))
	{
		if (open != self.tab)
		{
			self.toast("That file is open in another tab");
			return;
		}
	}
	if (catch excuse = store::save(&self.tab.board, self.tab.view(), path))
	{
		self.toast("Could not save %s (%s)", path, excuse);
		return;
	}
	if (self.tab.path.ptr) free(self.tab.path.ptr);
	self.tab.path = path.copy(mem);
	self.tab.saved_revision = self.tab.board.revision;
	self.tab.view_dirty = false;
	self.tab.save_failed = false;
	self.toast("Saved");
	self.update_title();
}

<*
 Finishes and saves any editing in progress before a file operation.
*>
fn void App.settle(&self)
{
	if (self.edit_id) self.finish_edit();
	self.tab.board.commit();
}

<*
 Shows the tab a dialog was opened from, which may no longer be the one on screen.

 @return "false if that tab has closed since"
*>
fn bool App.show_dialog_tab(&self)
{
	foreach (tab : self.open_tabs())
	{
		if (tab.serial != self.dialog_tab) continue;
		self.show_tab(tab);
		return true;
	}
	self.toast("That board has been closed");
	return false;
}

fn void App.handle_dialog(&self)
{
	if (self.mode != IDLE) return; // what the pointer is doing finishes first
	Request request;
	String reply;
	switch (dialog::poll(&request, &reply))
	{
		case UNAVAILABLE:
			self.toast("File dialogs need zenity. You can also drop files on the window.");
		case CHOSEN:
			self.settle();
			switch (request)
			{
				case OPEN_BOARD: self.open(reply);
				case NEW_BOARD: self.new_board(with_extension(reply, ".tabla"));
				case SAVE_BOARD:
					if (self.show_dialog_tab()) self.save_as(with_extension(reply, ".tabla"));
				case ADD_IMAGES:
					if (!self.show_dialog_tab()) break;
					@pool()
					{
						self.add_files(reply.tsplit("\n"), self.view_center());
					};
				case EXPORT_PNG:
					if (self.show_dialog_tab()) self.export_board(with_extension(reply, ".png"));
			}
		default:
			break;
	}
}

fn String with_extension(String path, String extension) @local
{
	return path.ends_with(extension) ? path : path.tconcat(extension);
}

fn Vec2 App.view_center(&self) => { self.input.width * 0.5f, self.input.height * 0.5f };

fn void App.export_board(&self, String path)
{
	self.tab.board.sync();
	DRect? area = self.selection.len() ? self.selection_bounds() : self.tab.board.extent();
	if (catch area)
	{
		self.toast("Nothing to export yet");
		return;
	}
	DVec2 margin = area.size() * 0.04 + 1e-6;
	area.lo -= margin;
	area.hi += margin;
	@pool()
	{
		if (self.gfx.export_png(&self.tab.board, area, self.tab.paper, path.zstr_tcopy()))
		{
			self.toast("Exported %s", path);
		}
		else
		{
			self.toast("Could not export to %s", path);
		}
	};
}

<*
 Recognises a picture by its contents. File names lie, and web downloads especially
 often carry the wrong extension.
*>
fn String? sniff_picture(char[] b)
{
	if (b.len < 12) return UNSUPPORTED~;
	if (b[0] == 0x89 && b[1] == 'P') return ".png";
	if (b[0] == 0xFF && b[1] == 0xD8) return ".jpg";
	if (b[0] == 'G' && b[1] == 'I' && b[2] == 'F') return ".gif";
	if (b[0] == 'B' && b[1] == 'M') return ".bmp";
	if (b[0] == 'q' && b[1] == 'o' && b[2] == 'i' && b[3] == 'f') return ".qoi";
	if ((String)b[8:4] == "WEBP") return WEBP~;
	return UNSUPPORTED~;
}

excuse UNSUPPORTED, WEBP, UNREADABLE;

<*
 Adds a picture from encoded bytes, taking ownership of them.
*>
fn Item*? App.add_picture(&self, char[] bytes, DVec2 center)
{
	String? extension = sniff_picture(bytes);
	if (catch excuse = extension)
	{
		free(bytes.ptr);
		return excuse~;
	}
	RLImage image;
	@pool()
	{
		image = rl::load_image_from_memory(extension.zstr_tcopy(), bytes.ptr, (int)bytes.len);
	};
	if (!image.data)
	{
		free(bytes.ptr);
		return UNREADABLE~;
	}
	defer rl::unload_image(image);

	render::orient_image(&image, geom::jpeg_orientation(bytes));
	Asset* asset = self.tab.board.add_asset(bytes, extension, image.width, image.height, fnv64a::hash(bytes));
	if (asset.state == UNLOADED) render::upload_picture(asset, &image);

	// Keep the original pixel size unless that would not fit comfortably on screen.
	double fit = math::min(self.input.width * 0.6 / asset.width, self.input.height * 0.6 / asset.height, 1.0);
	double scale = fit / self.tab.cam.zoom;
	Vec2 size = { (float)asset.width, (float)asset.height };
	DVec2 pos = center - (DVec2)size * scale * 0.5;
	return self.tab.board.add({ .kind = IMAGE, .pos = pos, .scale = scale, .size = size, .asset = asset });
}

fn void App.select_only_new(&self, uint[] ids)
{
	self.selection.clear();
	self.selection.push_all(ids);
	self.tool = SELECT;
}

fn void App.add_files(&self, String[] paths, Vec2 at)
{
	// Boards first: pictures dropped along with one go on the board that ends up open.
	foreach (path : paths)
	{
		if (path.ends_with(".tabla")) self.open(path);
	}
	List{uint} added;
	added.init(mem);
	defer added.free();
	DVec2 center = self.tab.cam.to_world(at);
	double step = 28 / self.tab.cam.zoom;
	foreach (path : paths)
	{
		if (!path.len || path.ends_with(".tabla")) continue;
		char[]? bytes = file::load(mem, path);
		if (catch bytes)
		{
			self.toast("Could not read %s", path);
			continue;
		}
		Item*? item = self.add_picture(bytes, center);
		if (catch excuse = item)
		{
			self.report_picture_error(excuse, path);
			continue;
		}
		added.push(item.id);
		center += step;
		self.limit_textures();
	}
	self.tab.board.commit();
	if (added.len()) self.select_only_new(added.array_view());
}

fn void App.report_picture_error(&self, fault excuse, String name)
{
	if (excuse == WEBP)
	{
		self.toast("WebP is not supported yet: %s", name);
	}
	else
	{
		self.toast("Not a picture Tabla can read: %s", name);
	}
}

fn Item*[] App.group(&self, Allocator allocator = tmem)
{
	HashMap{uint, bool} chosen;
	chosen.tinit();
	foreach (id : self.selection) chosen[id] = true;
	List{Item*} group;
	group.init(allocator);
	foreach (item : self.tab.board.items)
	{
		if (item.dead) continue;
		if (chosen.has_key(item.id) || (item.parent && chosen.has_key(item.parent))) group.push(item);
	}
	return group.array_view();
}

fn DRect? App.selection_bounds(&self)
{
	DRect? box = NOT_SELECTED~;
	foreach (id : self.selection)
	{
		Item*? item = self.tab.board.get(id);
		if (catch item) continue;
		if (try known = box)
		{
			box = known.merge(item.bounds());
		}
		else
		{
			box = item.bounds();
		}
	}
	return box;
}

excuse NOT_SELECTED;

fn void App.prune_selection(&self)
{
	sz out = 0;
	foreach (id : self.selection)
	{
		if (self.tab.board.by_id.has_key(id)) self.selection[out++] = id;
	}
	while (self.selection.len() > out) (void)self.selection.pop();
}

fn bool App.is_selected(&self, uint id)
{
	foreach (known : self.selection)
	{
		if (known == id) return true;
	}
	return false;
}

fn void App.set_tool(&self, Tool tool)
{
	if (self.edit_id) self.finish_edit();
	self.tool = tool;
	if (tool != SELECT) self.selection.clear();
}

// Commands

fn void App.undo(&self)
{
	self.settle();
	if (self.tab.board.undo()) self.prune_selection();
}

fn void App.redo(&self)
{
	self.settle();
	if (self.tab.board.redo()) self.prune_selection();
}

fn void App.delete_selection(&self)
{
	@pool()
	{
		foreach (item : self.group()) self.tab.board.remove(item);
	};
	self.tab.board.commit();
	self.selection.clear();
}

fn void App.bring_to_front(&self)
{
	@pool()
	{
		foreach (item : self.group()) self.tab.board.bring_to_front(item);
	};
	self.tab.board.commit();
}

fn void App.send_to_back(&self)
{
	@pool()
	{
		Item*[] group = self.group();
		for (sz i = group.len; i > 0; i--) self.tab.board.send_to_back(group[i - 1]);
	};
	self.tab.board.commit();
}

fn void App.collect_selection(&self, List{Item}* out)
{
	@pool()
	{
		foreach (item : self.group())
		{
			Item copy = *item;
			copy.retain();
			out.push(copy);
		}
	};
}

fn void App.copy(&self)
{
	self.clear_clip();
	self.collect_selection(&self.clip_items);
	foreach (&item : self.clip_items)
	{
		if (item.kind == IMAGE) item.asset = self.clip_board.adopt_asset(item.asset);
	}
	// The items stay in memory; the marker tells a later paste that nothing newer was
	// copied elsewhere in the meantime.
	if (self.scripted) return;
	@pool()
	{
		rl::set_clipboard_text(CLIP_MARKER.zstr_tcopy());
	};
}

<*
 Places copies of `items`, moved so that their centre lands on `center`.
*>
fn void App.place_copies(&self, List{Item}* items, DVec2 center)
{
	if (items.is_empty()) return;
	DRect box = items.get_ref(0).bounds();
	foreach (&item : items) box = box.merge(item.bounds());
	DVec2 shift = center - (box.lo + box.hi) * 0.5;

	HashMap{uint, uint} new_ids;
	new_ids.init(mem);
	defer new_ids.free();
	List{uint} added;
	added.init(mem);
	defer added.free();
	foreach (&source : items)
	{
		Item copy = *source;
		if (copy.kind == IMAGE) copy.asset = self.tab.board.adopt_asset(copy.asset);
		copy.retain();
		copy.id = 0;
		copy.z = 0;
		copy.pos += shift;
		copy.parent = 0;
		Item* placed = self.tab.board.add(copy);
		new_ids[source.id] = placed.id;
		if (!source.parent || !list_contains(items, source.parent)) added.push(placed.id);
	}
	// Pinned ink follows its picture into the copy.
	foreach (&source : items)
	{
		if (!source.parent) continue;
		uint? parent = new_ids.get(source.parent);
		if (try parent) self.tab.board.get(new_ids[source.id]!!)!!.parent = parent;
	}
	self.tab.board.commit();
	self.select_only_new(added.array_view());
}

fn bool list_contains(List{Item}* items, uint id) @local
{
	foreach (&item : items)
	{
		if (item.id == id) return true;
	}
	return false;
}

fn void App.duplicate(&self)
{
	if (self.selection.is_empty()) return;
	DRect? box = self.selection_bounds();
	if (catch box) return;
	List{Item} copies;
	copies.init(mem);
	defer
	{
		foreach (&item : copies) item.release();
		copies.free();
	}
	self.collect_selection(&copies);
	self.place_copies(&copies, (box.lo + box.hi) * 0.5 + 24 / self.tab.cam.zoom);
}

fn void App.paste(&self, Vec2 at)
{
	clip::Content content = clip::read(rl::get_window_handle());
	defer content.free();
	self.paste_content(&content, at);
}

fn void App.paste_content(&self, clip::Content* content, Vec2 at)
{
	switch (content.kind)
	{
		case PICTURE:
			char[] bytes = mem::new_array(char, content.bytes.len());
			bytes[..] = content.bytes.array_view()[..];
			Item*? item = self.add_picture(bytes, self.tab.cam.to_world(at));
			if (catch excuse = item)
			{
				self.report_picture_error(excuse, "the clipboard");
				return;
			}
			uint[1] id = { item.id };
			self.tab.board.commit();
			self.select_only_new(&id);
		case FILES:
			@pool()
			{
				self.add_files(clip::parse_uri_list((String)content.bytes.array_view()), at);
			};
		case OTHER:
		case NOTHING:
			ZString text = rl::get_clipboard_text();
			String value = text ? text.str_view() : "";
			if (value == CLIP_MARKER)
			{
				self.place_copies(&self.clip_items, self.tab.cam.to_world(at));
			}
			else if (value.len)
			{
				self.place_text(value, self.tab.cam.to_world(at));
			}
			else
			{
				self.toast("The clipboard is empty");
			}
	}
}

fn void App.place_text(&self, String text, DVec2 world)
{
	Vec2 size = self.gfx.measure(text, 0);
	double scale = self.text_scale();
	Item* item = self.tab.board.add({
		.kind = TEXT, .pos = world - (DVec2)size * scale * 0.5, .scale = scale, .size = size,
		.color = self.styles[Tool.TEXT.ordinal].color, .text = board::text_new(text)
	});
	uint[1] id = { item.id };
	self.tab.board.commit();
	self.select_only_new(&id);
}

fn double App.text_scale(&self)
{
	return (double)(self.styles[Tool.TEXT.ordinal].size / render::TEXT_SIZE) / self.tab.cam.zoom;
}

<*
 Changes the colour of what is selected. Notes change their paper, everything else
 its ink, and ink keeps its own transparency.
*>
fn void App.recolor_selection(&self, Rgba color, bool commit = true)
{
	foreach (id : self.selection)
	{
		Item*? item = self.tab.board.get(id);
		if (catch item) continue;
		if (item.kind == IMAGE) continue;
		if (item.kind == TEXT && item.fill.a)
		{
			self.tab.board.touch(item).fill = color;
			continue;
		}
		color.a = item.color.a;
		self.tab.board.touch(item).color = color;
	}
	if (commit) self.tab.board.commit();
}

// View

fn void App.zoom_at(&self, Vec2 screen, double factor)
{
	Camera* t = &self.tab.cam_target;
	DVec2 anchor = t.to_world(screen);
	t.zoom = math::clamp(t.zoom * factor, MIN_ZOOM, MAX_ZOOM);
	t.origin = anchor - (DVec2)screen / t.zoom;
	self.tab.view_dirty = true;
}

fn void App.fit_view(&self, DRect box)
{
	DVec2 size = box.size();
	double zoom = math::min(self.input.width * 0.86 / math::max(size.x, 1e-9), self.input.height * 0.8 / math::max(size.y, 1e-9));
	zoom = math::clamp(zoom, MIN_ZOOM, MAX_ZOOM);
	self.tab.cam_target.zoom = zoom;
	self.tab.cam_target.origin = (box.lo + box.hi) * 0.5 - (DVec2)self.view_center() / zoom;
	self.tab.view_dirty = true;
}

fn void App.fit_all(&self)
{
	DRect? box = self.tab.board.extent();
	if (try box)
	{
		self.fit_view(box);
	}
	else
	{
		self.tab.cam_target = { .origin = { 0, 0 }, .zoom = 1 };
	}
}

fn bool App.camera_moving(&self)
{
	Camera* a = &self.tab.cam;
	Camera* b = &self.tab.cam_target;
	return a.zoom != b.zoom || a.origin != b.origin;
}

<*
 Eases the camera towards its target. Any change of pan and zoom has one screen point
 that stays still, and easing around that point keeps the spot under the mouse pinned
 during a wheel zoom, and makes "fit" read as a single smooth move.
*>
fn void App.step_camera(&self, float dt)
{
	if (!self.camera_moving()) return;
	Camera* c = &self.tab.cam;
	Camera* t = &self.tab.cam_target;
	double k = 1 - math::exp(-(double)math::clamp(dt, 0.0f, 0.1f) * 20);
	double ratio = t.zoom / c.zoom;
	double zoom = c.zoom * math::pow(ratio, k);
	DVec2 origin;
	if (math::abs(ratio - 1) < 1e-6)
	{
		origin = c.origin + (t.origin - c.origin) * k;
	}
	else
	{
		DVec2 still = (c.origin * c.zoom - t.origin * t.zoom) / (c.zoom - t.zoom);
		origin = still - (still - c.origin) * (c.zoom / zoom);
	}
	c.zoom = zoom;
	c.origin = origin;
	DVec2 miss = (c.origin - t.origin) * t.zoom;
	if (math::abs(ratio - 1) < 0.0015 && math::abs(miss.x) < 0.3 && math::abs(miss.y) < 0.3) *c = *t;
}

fn void App.pan_by(&self, Vec2 delta)
{
	DVec2 shift = (DVec2)delta / self.tab.cam.zoom;
	self.tab.cam.origin -= shift;
	self.tab.cam_target.origin -= shift;
	self.tab.view_dirty = true;
}

// Ink

fn void App.begin_stroke(&self, DVec2 world)
{
	Capture* c = &self.capture;
	PenStyle* style = &self.styles[self.tool.ordinal];
	float width = style.size / (float)self.tab.cam.zoom;
	c.points.clear();
	c.origin = world;
	c.filtered = { 0, 0 };
	c.raw = { 0, 0 };
	c.follow = 1 - style.smoothing * 0.88f;
	c.base_width = width;
	c.width = width;
	c.last_time = self.input.time;
	c.speed_width = self.tool == BRUSH;
	c.smooth = self.tool.is_ink();
	c.tip = self.tool == MARKER ? CHISEL : self.tool == HIGHLIGHTER ? WEDGE : ROUND;
	c.color = style.color;
	c.color.a = (char)(style.opacity * 255);
	c.points.push({ 0, 0, width });

	// Ink that starts on a picture belongs to it, and travels with it from now on.
	Item*? below = self.tab.board.item_at(world, 0, images_only: true);
	c.parent = 0;
	if (try below) c.parent = below.id;
}

fn void App.add_sample(&self, Sample sample)
{
	Capture* c = &self.capture;
	Vec2 local = (Vec2)(self.tab.cam.to_world(sample.pos) - c.origin);
	c.raw = local;
	c.filtered += (local - c.filtered) * c.follow;
	float pixel = 1 / (float)self.tab.cam.zoom;
	Vec2 last = geom::pos_of(c.points[c.points.len() - 1]);
	float moved = geom::length(c.filtered - last);
	if (moved < pixel * 0.75f) return;
	if (c.speed_width)
	{
		double elapsed = math::max(sample.time - c.last_time, 0.002);
		float speed = moved / pixel / (float)elapsed; // pixels per second
		float target = c.base_width * math::clamp(1.45f - speed / 1400, 0.3f, 1.45f);
		c.width += (target - c.width) * 0.22f;
	}
	c.last_time = sample.time;
	c.points.push({ c.filtered.x, c.filtered.y, c.width });
}

fn void App.finish_stroke(&self)
{
	Capture* c = &self.capture;
	Vec2 last = geom::pos_of(c.points[c.points.len() - 1]);
	// The stabiliser lags behind the pen: the stroke should still end at the pen.
	if (geom::length(c.raw - last) > 0.5f / (float)self.tab.cam.zoom) c.points.push({ c.raw.x, c.raw.y, c.width });
	if (c.speed_width)
	{
		sz n = c.points.len();
		sz taper = math::min(n / 2, (sz)12);
		for (sz i = 0; i < taper; i++)
		{
			float f = 0.2f + 0.8f * (float)(i + 1) / (float)(taper + 1);
			c.points.get_ref(i).w *= f;
			c.points.get_ref(n - 1 - i).w *= f;
		}
	}
	self.commit_capture();
}

fn void App.commit_capture(&self)
{
	Capture* c = &self.capture;
	InkPoint[] points = c.points.to_array(mem);
	self.tab.board.add({
		.kind = INK, .pos = c.origin, .scale = 1, .color = c.color, .parent = c.parent,
		.ink = board::ink_new(points, c.smooth, c.tip)
	});
	self.tab.board.commit();
}

fn void App.build_shape(&self, DVec2 world, bool constrain)
{
	Capture* c = &self.capture;
	Vec2 end = (Vec2)(world - c.origin);
	float w = c.base_width;
	c.points.clear();
	switch (self.tool)
	{
		case LINE:
		case ARROW:
			if (constrain)
			{
				float step = (float)math::PI / 12;
				float angle = math::round(math::atan2(end.y, end.x) / step) * step;
				float length = geom::length(end);
				end = { math::cos(angle) * length, math::sin(angle) * length };
			}
			c.points.push({ 0, 0, w });
			c.points.push({ end.x, end.y, w });
			float length = geom::length(end);
			if (self.tool == ARROW && length > 0)
			{
				float head = math::min(math::max(w * 4.5f, 14 / (float)self.tab.cam.zoom), length * 0.5f);
				Vec2 back = geom::normalize(end) * -head;
				Vec2 side = geom::perp(back) * 0.55f;
				Vec2 wing_a = end + back + side;
				Vec2 wing_b = end + back - side;
				c.points.push({ wing_a.x, wing_a.y, w });
				c.points.push({ end.x, end.y, w });
				c.points.push({ wing_b.x, wing_b.y, w });
			}
		case RECT:
			if (constrain) end = square_up(end);
			c.points.push({ 0, 0, w });
			c.points.push({ end.x, 0, w });
			c.points.push({ end.x, end.y, w });
			c.points.push({ 0, end.y, w });
			c.points.push({ 0, 0, w });
		case ELLIPSE:
			if (constrain) end = square_up(end);
			Vec2 middle = end * 0.5f;
			const int SEGMENTS = 96;
			for (int i = 0; i <= SEGMENTS; i++)
			{
				float a = (float)i / SEGMENTS * (float)math::PI * 2;
				c.points.push({ middle.x + math::cos(a) * middle.x, middle.y + math::sin(a) * middle.y, w });
			}
		default:
			break;
	}
}

fn Vec2 square_up(Vec2 v) @local
{
	float side = math::max(math::abs(v.x), math::abs(v.y));
	return { v.x < 0 ? -side : side, v.y < 0 ? -side : side };
}

// Eraser

fn void App.erase_along(&self, DVec2 from, DVec2 to, bool whole_strokes)
{
	double radius = self.styles[Tool.ERASER.ordinal].size * 0.5 / self.tab.cam.zoom;
	DRect swept = geom::rect_of(from, to);
	swept.lo -= radius;
	swept.hi += radius;
	sz count = self.tab.board.items.len(); // items added below need no checking
	for (sz i = 0; i < count; i++)
	{
		Item* item = self.tab.board.items[i];
		if (item.dead || item.kind != INK || !item.bounds().overlaps(swept)) continue;
		self.erase_from(item, from, to, radius, whole_strokes);
	}
}

fn void App.erase_from(&self, Item* item, DVec2 from, DVec2 to, double radius, bool whole_strokes)
{
	Vec2 a = (Vec2)((from - item.pos) / item.scale);
	Vec2 b = (Vec2)((to - item.pos) / item.scale);
	float r = (float)(radius / item.scale);
	List{InkPoint[]} runs;
	runs.init(mem);
	defer runs.free();
	if (!geom::erase_capsule(item.ink.points, a, b, r, &runs)) return;
	if (whole_strokes)
	{
		foreach (run : runs) free(run.ptr);
		self.tab.board.remove(item);
		return;
	}
	foreach (run : runs)
	{
		Item piece = *item;
		piece.id = 0;
		piece.ink = board::ink_new(run, item.ink.smooth, item.ink.tip);
		self.tab.board.add(piece);
	}
	self.tab.board.remove(item);
}

// Text

fn void App.begin_edit(&self, Item* item, bool is_new)
{
	self.tab.board.touch(item);
	self.edit_id = item.id;
	self.edit_is_new = is_new;
	self.edit_text.clear();
	self.edit_text.push_all((char[])item.text.text);
	self.edit_caret = self.edit_text.len();
	self.caret_blink = self.input.time;
	self.selection.clear();
	self.sync_edit();
}

fn String App.edit_string(&self) => (String)self.edit_text.array_view();

// Keeps the live preview and the size of the box in step with the text being typed.
fn void App.sync_edit(&self)
{
	Item*? item = self.tab.board.get(self.edit_id);
	if (catch item) return;
	String text = self.edit_string();
	self.gfx.edit_id = item.id;
	self.gfx.edit_text = text;
	if (item.fill.a)
	{
		Vec2 needed = self.gfx.measure(text, NOTE_SIZE - render::NOTE_PAD * 2);
		item.size = { NOTE_SIZE, math::max(NOTE_SIZE, needed.y + render::NOTE_PAD * 2) };
	}
	else
	{
		Vec2 needed = self.gfx.measure(text, 0);
		item.size = { math::max(needed.x, 12.0f), needed.y };
	}
}

fn void App.finish_edit(&self)
{
	uint id = self.edit_id;
	self.edit_id = 0;
	self.gfx.edit_id = 0;
	Item*? item = self.tab.board.get(id);
	if (catch item) return;
	String text = self.edit_string();
	if (!text.trim().len && !item.fill.a)
	{
		self.tab.board.remove(item);
	}
	else if (text != item.text.text)
	{
		item.release();
		item.text = board::text_new(text);
	}
	self.tab.board.commit();
}

fn void App.edit_insert(&self, String text)
{
	foreach (i, c : text) self.edit_text.insert_at(self.edit_caret + i, c);
	self.edit_caret += text.len;
}

fn void App.edit_left(&self)
{
	if (!self.edit_caret) return;
	self.edit_caret--;
	while (self.edit_caret > 0 && (self.edit_text[self.edit_caret] & 0xC0) == 0x80) self.edit_caret--;
}

fn void App.edit_right(&self)
{
	sz len = self.edit_text.len();
	if (self.edit_caret >= len) return;
	self.edit_caret++;
	while (self.edit_caret < len && (self.edit_text[self.edit_caret] & 0xC0) == 0x80) self.edit_caret++;
}

fn void App.edit_delete_before(&self)
{
	sz end = self.edit_caret;
	self.edit_left();
	for (sz i = end; i > self.edit_caret; i--) self.edit_text.remove_at(self.edit_caret);
}

fn void App.update_edit(&self, Input* in)
{
	bool changed = false;
	for (int i = 0; i < in.char_count; i++)
	{
		char[4] utf8;
		sz? size = conv::char32_to_utf8((Char32)in.chars[i], &utf8);
		if (catch size) continue;
		self.edit_insert((String)utf8[:size]);
		changed = true;
	}
	if (in.key(ESCAPE) || (in.key(ENTER) && in.ctrl))
	{
		self.finish_edit();
		return;
	}
	if (in.key(ENTER) || in.key(KP_ENTER))
	{
		self.edit_insert("\n");
		changed = true;
	}
	if (in.key(BACKSPACE))
	{
		self.edit_delete_before();
		changed = true;
	}
	if (in.key(DELETE) && self.edit_caret < self.edit_text.len())
	{
		self.edit_right();
		self.edit_delete_before();
		changed = true;
	}
	if (in.key(LEFT)) self.edit_left();
	if (in.key(RIGHT)) self.edit_right();
	if (in.key(HOME))
	{
		while (self.edit_caret > 0 && self.edit_text[self.edit_caret - 1] != '\n') self.edit_left();
	}
	if (in.key(END))
	{
		while (self.edit_caret < self.edit_text.len() && self.edit_text[self.edit_caret] != '\n') self.edit_right();
	}
	if (in.ctrl && in.letter('v'))
	{
		ZString text = rl::get_clipboard_text();
		if (text)
		{
			self.edit_insert(text.str_view());
			changed = true;
		}
	}
	for (int key = 0; key < in.pressed.len; key++)
	{
		if (in.pressed[key]) self.caret_blink = in.time;
	}
	if (changed) self.sync_edit();
}

fn void App.start_text(&self, DVec2 world)
{
	Item* item = self.tab.board.add({
		.kind = TEXT, .pos = world, .scale = self.text_scale(), .size = { 12, render::LINE_HEIGHT },
		.color = self.styles[Tool.TEXT.ordinal].color, .text = board::text_new("")
	});
	self.begin_edit(item, true);
}

fn void App.start_note(&self, DVec2 world)
{
	double scale = 1 / self.tab.cam.zoom;
	DVec2 pos = world - (double)NOTE_SIZE * 0.5 * scale;
	Item* item = self.tab.board.add({
		.kind = TEXT, .pos = pos, .scale = scale, .size = { NOTE_SIZE, NOTE_SIZE },
		.color = { 30, 30, 34, 255 }, .fill = self.styles[Tool.NOTE.ordinal].color,
		.text = board::text_new("")
	});
	self.begin_edit(item, true);
}

// Pointer

fn void App.remember_poses(&self)
{
	self.poses.clear();
	@pool()
	{
		foreach (item : self.group()) self.poses.push({ item.id, item.pos, item.scale });
	};
}

<*
 The corner of the selection handle under a screen position: 0 to 3 clockwise from the
 top left, or -1.
*>
fn int App.handle_at(&self, Vec2 mouse)
{
	DRect? box = self.selection_bounds();
	if (catch box) return -1;
	Vec2 lo = self.tab.cam.to_screen(box.lo);
	Vec2 hi = self.tab.cam.to_screen(box.hi);
	Vec2[4] corners = { lo, { hi.x, lo.y }, hi, { lo.x, hi.y } };
	foreach (i, corner : corners)
	{
		if (geom::length(mouse - corner) <= HANDLE_REACH) return (int)i;
	}
	return -1;
}

fn void App.begin_resize(&self, int corner)
{
	DRect? box = self.selection_bounds();
	if (catch box) return;
	DVec2[4] corners = { box.lo, { box.hi.x, box.lo.y }, box.hi, { box.lo.x, box.hi.y } };
	self.resize_box = box;
	self.resize_corner = corner;
	self.resize_anchor = corners[(corner + 2) % 4];
	self.remember_poses();
	self.mode = RESIZING;
}

fn void App.apply_resize(&self, DVec2 world)
{
	DRect box = self.resize_box;
	DVec2[4] corners = { box.lo, { box.hi.x, box.lo.y }, box.hi, { box.lo.x, box.hi.y } };
	DVec2 start = corners[self.resize_corner] - self.resize_anchor;
	DVec2 now = world - self.resize_anchor;
	double along = (now.x * start.x + now.y * start.y) / (start.x * start.x + start.y * start.y);
	double factor = math::max(along, 0.02);
	foreach (pose : self.poses)
	{
		Item*? item = self.tab.board.get(pose.id);
		if (catch item) continue;
		self.tab.board.touch(item);
		item.pos = self.resize_anchor + (pose.pos - self.resize_anchor) * factor;
		item.scale = pose.scale * factor;
	}
}

fn void App.apply_move(&self, DVec2 world)
{
	DVec2 shift = world - self.press_world;
	foreach (pose : self.poses)
	{
		Item*? item = self.tab.board.get(pose.id);
		if (catch item) continue;
		self.tab.board.touch(item).pos = pose.pos + shift;
	}
}

fn void App.press_with_select(&self, Input* in, DVec2 world)
{
	int corner = self.handle_at(in.mouse);
	if (corner >= 0)
	{
		self.begin_resize(corner);
		return;
	}
	double reach = 5 / self.tab.cam.zoom;
	Item*? item = self.tab.board.item_at(world, reach);
	if (catch item)
	{
		if (!in.shift) self.selection.clear();
		self.mode = MARQUEE;
		return;
	}
	bool double_click = in.time - self.last_press_time < DOUBLE_CLICK_SECONDS
		&& geom::length(in.mouse - self.last_press_pos) < 6;
	self.last_press_time = in.time;
	self.last_press_pos = in.mouse;
	if (double_click && item.kind == TEXT)
	{
		self.begin_edit(item, false);
		return;
	}
	if (in.shift)
	{
		if (self.is_selected(item.id))
		{
			foreach (i, id : self.selection)
			{
				if (id == item.id)
				{
					self.selection.remove_at(i);
					break;
				}
			}
			return;
		}
		self.selection.push(item.id);
	}
	else if (!self.is_selected(item.id))
	{
		self.selection.clear();
		self.selection.push(item.id);
	}
	self.remember_poses();
	self.mode = PRESSING;
}

fn void App.press_on_canvas(&self, Input* in)
{
	self.press_screen = in.mouse;
	DVec2 world = self.tab.cam.to_world(in.mouse);
	self.press_world = world;
	Tool tool = self.tool;
	if (tool.is_ink())
	{
		self.begin_stroke(world);
		self.mode = INKING;
	}
	else if (tool.is_shape())
	{
		self.begin_stroke(world);
		self.mode = SHAPING;
	}
	else if (tool == ERASER)
	{
		self.last_erase = world;
		self.erase_along(world, world, in.shift);
		self.mode = ERASING;
	}
	else if (tool == TEXT)
	{
		self.start_text(world);
	}
	else if (tool == NOTE)
	{
		self.start_note(world);
	}
	else if (tool == SELECT)
	{
		self.press_with_select(in, world);
	}
}

fn void App.finish_marquee(&self, Input* in)
{
	DRect area = geom::rect_of(self.press_world, self.tab.cam.to_world(in.mouse));
	HashMap{uint, bool} chosen;
	chosen.tinit();
	foreach (id : self.selection) chosen[id] = true;
	foreach (item : self.tab.board.items)
	{
		// Pinned ink travels with its picture, so only the picture needs selecting.
		if (item.dead || (item.parent && self.tab.board.by_id.has_key(item.parent))) continue;
		if (item.in_rect(area) && !chosen.has_key(item.id)) self.selection.push(item.id);
	}
}

fn void App.update_pointer(&self, Input* in, bool over_ui)
{
	DVec2 world = self.tab.cam.to_world(in.mouse);
	switch (self.mode)
	{
		case IDLE:
			bool panning_tool = self.tool == HAND || in.held(SPACE);
			if (in.pan_pressed && !over_ui)
			{
				self.mode = PANNING;
			}
			else if (in.left_pressed && !over_ui)
			{
				bool was_typing = self.edit_id != 0;
				if (was_typing) self.finish_edit();
				self.tab.board.sync();
				if (panning_tool)
				{
					self.mode = PANNING;
				}
				else if (!was_typing || (self.tool != TEXT && self.tool != NOTE))
				{
					// A click that ends typing should not start another text right away.
					self.press_on_canvas(in);
				}
			}
			self.hover_id = 0;
			if (self.tool == SELECT && self.mode == IDLE && !over_ui)
			{
				Item*? below = self.tab.board.item_at(world, 5 / self.tab.cam.zoom);
				if (try below) self.hover_id = below.id;
			}
		case PANNING:
			self.pan_by(in.delta);
			if (!in.left_down && !in.pan_down) self.mode = IDLE;
		case INKING:
			for (int i = 0; i < in.trail_count; i++) self.add_sample(in.trail[i]);
			if (!in.trail_count) self.add_sample({ in.mouse, in.time });
			if (!in.left_down)
			{
				self.finish_stroke();
				self.mode = IDLE;
			}
		case SHAPING:
			self.build_shape(world, in.shift);
			if (!in.left_down)
			{
				if (geom::length(in.mouse - self.press_screen) >= DRAG_THRESHOLD) self.commit_capture();
				self.capture.points.clear();
				self.mode = IDLE;
			}
		case ERASING:
			self.erase_along(self.last_erase, world, in.shift);
			self.last_erase = world;
			if (!in.left_down)
			{
				self.tab.board.commit();
				self.mode = IDLE;
			}
		case PRESSING:
			if (!in.left_down)
			{
				self.mode = IDLE;
			}
			else if (geom::length(in.mouse - self.press_screen) >= DRAG_THRESHOLD)
			{
				self.mode = MOVING;
			}
		case MOVING:
			self.apply_move(world);
			if (!in.left_down)
			{
				self.tab.board.commit();
				self.mode = IDLE;
			}
		case RESIZING:
			self.apply_resize(world);
			if (!in.left_down)
			{
				self.tab.board.commit();
				self.mode = IDLE;
			}
		case MARQUEE:
			if (!in.left_down)
			{
				self.finish_marquee(in);
				self.mode = IDLE;
			}
	}
}

fn void App.update_cursor(&self, Input* in, bool over_ui)
{
	bool hide = self.tool.draws() && !over_ui && !in.held(SPACE) && self.mode != PANNING;
	if (hide != self.cursor_hidden)
	{
		self.cursor_hidden = hide;
		if (hide)
		{
			rl::hide_cursor();
		}
		else
		{
			rl::show_cursor();
		}
	}
	if (hide) return;

	RLMouseCursor cursor = DEFAULT;
	if (over_ui)
	{
		cursor = POINTING_HAND;
	}
	else if (self.mode == PANNING || self.tool == HAND || in.held(SPACE))
	{
		cursor = RESIZE_ALL;
	}
	else if (self.edit_id || self.tool == TEXT)
	{
		cursor = IBEAM;
	}
	else if (self.tool == NOTE)
	{
		cursor = CROSSHAIR;
	}
	else if (self.mode == RESIZING)
	{
		cursor = self.resize_corner % 2 ? RESIZE_NESW : RESIZE_NWSE;
	}
	else if (self.tool == SELECT)
	{
		int corner = self.handle_at(in.mouse);
		if (corner >= 0)
		{
			cursor = corner % 2 ? RESIZE_NESW : RESIZE_NWSE;
		}
		else if (self.mode == MOVING || self.hover_id)
		{
			cursor = RESIZE_ALL;
		}
	}
	rl::set_mouse_cursor(cursor);
}

// Keyboard

fn void App.handle_shortcuts(&self, Input* in)
{
	if (in.tapped(F1)) self.help_open = !self.help_open;
	if (self.help_open)
	{
		if (in.key(ESCAPE)) self.help_open = false;
		return;
	}
	if (self.mode != IDLE) return;
	if (in.ctrl)
	{
		if (in.letter('z'))
		{
			if (in.shift)
			{
				self.redo();
			}
			else
			{
				self.undo();
			}
		}
		if (in.letter('y')) self.redo();
		if (in.letter('s'))
		{
			self.settle();
			if (in.shift || !self.tab.path.len)
			{
				self.request_dialog(SAVE_BOARD);
			}
			else if (self.save_now(true))
			{
				self.toast("Saved");
			}
		}
		if (in.letter('o')) self.request_dialog(OPEN_BOARD);
		if (in.letter('n')) self.request_dialog(NEW_BOARD);
		if (in.letter('e')) self.request_dialog(EXPORT_PNG);
		if (in.letter('a'))
		{
			self.set_tool(SELECT);
			self.selection.clear();
			foreach (item : self.tab.board.items)
			{
				if (!item.parent || !self.tab.board.by_id.has_key(item.parent)) self.selection.push(item.id);
			}
		}
		if (in.letter('c') && self.selection.len()) self.copy();
		if (in.letter('x') && self.selection.len())
		{
			self.copy();
			self.delete_selection();
		}
		if (in.letter('v')) self.paste(in.mouse);
		if (in.letter('d')) self.duplicate();
		if (in.key(ZERO)) self.zoom_at(self.view_center(), 1 / self.tab.cam_target.zoom);
		if (in.key(ONE)) self.fit_all();
		return;
	}

	const char[*] LETTERS = "vhpbmyelaront";
	const Tool[*] TOOLS = { SELECT, HAND, PEN, BRUSH, MARKER, HIGHLIGHTER, ERASER, LINE, ARROW, RECT, ELLIPSE, TEXT, NOTE };
	foreach (i, letter : LETTERS)
	{
		if (in.letter(letter)) self.set_tool(TOOLS[i]);
	}
	if (in.letter('i')) self.request_dialog(ADD_IMAGES);
	if (in.key(EQUAL) || in.key(KP_ADD)) self.zoom_at(self.view_center(), 1.4);
	if (in.key(MINUS) || in.key(KP_SUBTRACT)) self.zoom_at(self.view_center(), 1 / 1.4);
	if (in.key(HOME)) self.fit_all();

	bool selecting = self.tool == SELECT && self.selection.len();
	if (selecting)
	{
		if (in.key(DELETE) || in.key(BACKSPACE)) self.delete_selection();
		if (in.key(RIGHT_BRACKET)) self.bring_to_front();
		if (in.key(LEFT_BRACKET)) self.send_to_back();
		Vec2 nudge = { 0, 0 };
		float step = in.shift ? 10 : 1;
		if (in.key(LEFT)) nudge.x -= step;
		if (in.key(RIGHT)) nudge.x += step;
		if (in.key(UP)) nudge.y -= step;
		if (in.key(DOWN)) nudge.y += step;
		if (nudge.x != 0 || nudge.y != 0)
		{
			@pool()
			{
				foreach (item : self.group()) self.tab.board.touch(item).pos += (DVec2)nudge / self.tab.cam.zoom;
			};
			self.tab.board.commit();
		}
	}
	else
	{
		float* size = &self.styles[self.tool.ordinal].size;
		if (in.key(RIGHT_BRACKET)) *size = math::min(*size * 1.2f + 0.5f, ui::MAX_PEN_SIZE);
		if (in.key(LEFT_BRACKET)) *size = math::max(*size / 1.2f - 0.5f, ui::MIN_PEN_SIZE);
	}
	if (in.key(ESCAPE))
	{
		self.selection.clear();
		self.tool = SELECT;
	}
}

fn void App.handle_tab_keys(&self, Input* in)
{
	if (!in.ctrl || self.help_open || self.mode != IDLE || dialog::is_open()) return;
	// First presses only. Input methods can repeat a key press, and between two tabs that
	// would go there and straight back. Held down, Ctrl+W would close every tab.
	if (in.tapped(TAB)) self.cycle_tab(in.shift ? -1 : 1);
	if (in.tapped(PAGE_DOWN)) self.cycle_tab(1);
	if (in.tapped(PAGE_UP)) self.cycle_tab(-1);
	if (in.letter_tapped('w')) self.close_tab(self.tab);
}

// The tab strip is drawn while a frame is under way, so what it asks for happens here.
fn void App.handle_tab_request(&self)
{
	Tab* show = self.ui.tab_to_show;
	Tab* close = self.ui.tab_to_close;
	self.ui.tab_to_show = null;
	self.ui.tab_to_close = null;
	if (show) self.show_tab(show);
	if (close) self.close_tab(close);
}

fn void App.request_dialog(&self, Request request)
{
	if (dialog::is_open()) return; // a held key repeats, and one dialog is enough
	if ((request == OPEN_BOARD || request == NEW_BOARD) && !self.has_room()) return;
	self.dialog_tab = self.tab.serial;
	dialog::start(request);
}

fn void App.handle_dropped_files(&self, Input* in)
{
	if (!rl::is_file_dropped()) return;
	RLFilePathList dropped = rl::load_dropped_files();
	defer rl::unload_dropped_files(dropped);
	@pool()
	{
		List{String} paths;
		paths.tinit();
		for (uint i = 0; i < dropped.count; i++) paths.push(dropped.paths[i].str_view());
		self.settle();
		self.add_files(paths.array_view(), in.mouse);
	};
}

fn bool App.busy(&self)
{
	if (self.camera_moving() || dialog::is_open() || self.edit_id || self.gfx.textures_waiting) return true;
	foreach (tab : self.open_tabs())
	{
		if (tab.has_unsaved()) return true;
	}
	return self.input.time < self.toast_until;
}

fn void App.update(&self, Input* in, bool over_ui)
{
	self.handle_tab_request();
	self.handle_dialog();
	self.handle_dropped_files(in);
	if (in.wheel != 0 && !over_ui && !self.help_open)
	{
		if (in.shift)
		{
			self.pan_by({ in.wheel * 60, 0 });
		}
		else
		{
			self.zoom_at(in.mouse, math::pow(1.2, (double)in.wheel));
		}
	}
	self.step_camera(in.dt);
	self.handle_tab_keys(in);
	if (self.edit_id)
	{
		self.update_edit(in);
	}
	else
	{
		self.handle_shortcuts(in);
	}
	if (!self.help_open) self.update_pointer(in, over_ui);
	self.update_cursor(in, over_ui);
	self.autosave();
}

fn void App.frame(&self) => @pool()
{
	Input* in = &self.input;
	self.tab.board.sync();
	self.ui.layout(self, in);
	bool over_ui = self.ui.covers(self, in);
	self.update(in, over_ui);
	self.tab.board.sync();

	rl::begin_drawing();
	self.gfx.begin_scene(in.width, in.height);
	self.gfx.draw_paper(&self.tab.cam, self.tab.paper, self.tab.pattern);
	self.gfx.draw_items(&self.tab.board, &self.tab.cam);
	self.limit_textures();
	self.draw_capture();
	self.ui.draw(self, in);
	$if $feat(E2E):
		if (self.capture_path.len)
		{
			render::flush_batch();
			@pool()
			{
				RLImage shot = rl::load_image_from_screen();
				rl::export_image(shot, self.capture_path.zstr_tcopy());
				rl::unload_image(shot);
			};
			self.capture_path = "";
		}
	$endif
	// This must come before end_drawing, which is where the wait happens. Set afterwards,
	// the last event before going idle would sleep with the previous choice: autosave
	// and camera easing would then stall until the next mouse move.
	if (self.scripted || self.busy())
	{
		rl::disable_event_waiting();
	}
	else
	{
		rl::enable_event_waiting();
	}
	rl::end_drawing();
}

fn void App.draw_capture(&self)
{
	Capture* c = &self.capture;
	if (self.mode == INKING)
	{
		// The stored stroke lags behind the pen; show it reaching the pen tip.
		c.points.push({ c.raw.x, c.raw.y, c.width });
		self.gfx.draw_live(&self.tab.cam, c.points.array_view(), c.smooth, c.tip, c.origin, c.color);
		(void)c.points.pop();
	}
	else if (self.mode == SHAPING && c.points.len())
	{
		self.gfx.draw_live(&self.tab.cam, c.points.array_view(), false, ROUND, c.origin, c.color);
	}
}
