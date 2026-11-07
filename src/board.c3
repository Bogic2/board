// The document: items, their z-order, and undo history. No drawing happens here.
module tabla::board;
import tabla::geom, raylib55::rl;
import std::math, std::sort, std::collections::list, std::collections::map;

alias Rgba = char[<4>];

const int MAX_UNDO = 512;

enum ItemKind : char
{
	INK,
	IMAGE,
	TEXT,
}

// Immutable stroke geometry. Undo snapshots and copies share it through `refs`.
struct Ink
{
	int refs;
	InkPoint[] points;
	Vec2 lo;
	Vec2 hi;
	bool smooth;
	Tip tip;
	// GPU mesh, created lazily by the renderer.
	uint vao;
	uint vbo;
	int vertex_count;
}

struct TextBlob
{
	int refs;
	String text;
}

enum TextureState : char
{
	UNLOADED,
	READY,
	FAILED,
}

// A picture's original encoded file. Assets live as long as the board does, so undoing
// a delete can always bring the picture back.
struct Asset
{
	uint id;
	char[] bytes;
	String extension;
	int width;
	int height;
	ulong hash;
	RLTexture2D texture;
	TextureState state;
}

struct Item
{
	uint id;
	uint parent; // the image this ink is pinned to, or 0
	long z;
	DVec2 pos; // world position of the local origin
	double scale;
	Vec2 size; // local size of an image or text box
	Rgba color;
	Rgba fill; // sticky note background; transparent for plain text
	ItemKind kind;
	bool dead;
	union
	{
		Ink* ink;
		Asset* asset;
		TextBlob* text;
	}
}

struct Change
{
	uint id;
	bool had_before;
	bool had_after;
	Item before;
	Item after;
}

alias Step = List{Change};

struct Board
{
	List{Item*} items; // bottom to top
	HashMap{uint, Item*} by_id;
	List{Asset*} assets;
	uint next_id;
	long z_top;
	long z_bottom;
	ulong revision; // bumped whenever the document changes
	bool needs_sync;

	List{Change} pending;
	HashMap{uint, int} pending_index;
	List{Step} undo_steps;
	List{Step} redo_steps;
}

fn Ink* ink_new(InkPoint[] points, bool smooth, Tip tip)
{
	Ink* ink = mem::new(Ink);
	ink.refs = 1;
	ink.points = points;
	ink.smooth = smooth;
	ink.tip = tip;
	ink.lo = { float::max, float::max };
	ink.hi = { -float::max, -float::max };
	foreach (p : points)
	{
		float r = p.w * 0.5f;
		ink.lo = { math::min(ink.lo.x, p.x - r), math::min(ink.lo.y, p.y - r) };
		ink.hi = { math::max(ink.hi.x, p.x + r), math::max(ink.hi.y, p.y + r) };
	}
	return ink;
}

fn TextBlob* text_new(String text)
{
	TextBlob* blob = mem::new(TextBlob);
	blob.refs = 1;
	blob.text = text.copy(mem);
	return blob;
}

fn void Item.retain(&self)
{
	switch (self.kind)
	{
		case INK: self.ink.refs++;
		case TEXT: self.text.refs++;
		case IMAGE: break;
	}
}

fn void Item.release(&self)
{
	switch (self.kind)
	{
		case INK:
			if (--self.ink.refs > 0) return;
			if (self.ink.vao)
			{
				rl::gl_unload_vertex_array(self.ink.vao);
				rl::gl_unload_vertex_buffer(self.ink.vbo);
			}
			free(self.ink.points.ptr);
			free(self.ink);
		case TEXT:
			if (--self.text.refs > 0) return;
			free(self.text.text.ptr);
			free(self.text);
		case IMAGE:
			break;
	}
}

fn DRect Item.bounds(&self)
{
	if (self.kind == INK)
	{
		return {
			.lo = self.pos + (DVec2)(self.ink.lo) * self.scale,
			.hi = self.pos + (DVec2)(self.ink.hi) * self.scale
		};
	}
	return { .lo = self.pos, .hi = self.pos + (DVec2)(self.size) * self.scale };
}

<*
 Whether the world point `p` lands on this item, with `tolerance` in world units.
*>
fn bool Item.hit(&self, DVec2 p, double tolerance)
{
	DRect box = self.bounds();
	box.lo -= tolerance;
	box.hi += tolerance;
	if (!box.contains(p)) return false;
	if (self.kind != INK) return true;

	Vec2 local = (Vec2)((p - self.pos) / self.scale);
	float slack = (float)(tolerance / self.scale);
	InkPoint[] points = self.ink.points;
	if (points.len == 1) return geom::length(local - geom::pos_of(points[0])) <= points[0].w * 0.5f + slack;
	for (sz i = 0; i + 1 < points.len; i++)
	{
		Vec2 a = geom::pos_of(points[i]);
		Vec2 b = geom::pos_of(points[i + 1]);
		if (geom::dist_to_segment(local, a, b) <= points[i].w * 0.5f + slack) return true;
	}
	return false;
}

<*
 Whether a marquee rectangle grabs this item. Ink needs a point inside the rectangle,
 since the bounding box of a long curve covers plenty of space the curve never touches.
*>
fn bool Item.in_rect(&self, DRect rect)
{
	if (!self.bounds().overlaps(rect)) return false;
	if (self.kind != INK) return true;
	foreach (p : self.ink.points)
	{
		DVec2 world = self.pos + (DVec2){ p.x, p.y } * self.scale;
		if (rect.contains(world)) return true;
	}
	return false;
}

fn void Board.init(&self)
{
	*self = {};
	// An uninitialised List allocates from the temp allocator on its first push, which
	// would leave these pointing at freed memory as soon as a @pool ends.
	self.items.init(mem);
	self.assets.init(mem);
	self.pending.init(mem);
	self.undo_steps.init(mem);
	self.redo_steps.init(mem);
	self.by_id.init(mem);
	self.pending_index.init(mem);
	self.next_id = 1;
}

fn void free_step(Step* step) @local
{
	foreach (&c : step)
	{
		if (c.had_before) c.before.release();
		if (c.had_after) c.after.release();
	}
	step.free();
}

fn void clear_steps(List{Step}* steps) @local
{
	foreach (&step : steps) free_step(step);
	steps.clear();
}

fn void Board.free(&self)
{
	foreach (&c : self.pending)
	{
		if (c.had_before) c.before.release();
	}
	self.pending.free();
	self.pending_index.free();
	clear_steps(&self.undo_steps);
	clear_steps(&self.redo_steps);
	self.undo_steps.free();
	self.redo_steps.free();
	foreach (item : self.items)
	{
		if (!item.dead) item.release();
		free(item);
	}
	self.items.free();
	self.by_id.free();
	foreach (asset : self.assets)
	{
		if (asset.state == READY) rl::unload_texture(asset.texture);
		free(asset.bytes.ptr);
		free(asset.extension.ptr);
		free(asset);
	}
	self.assets.free();
}

fn Item*? Board.get(&self, uint id) => self.by_id.get(id);

fn Asset*? Board.find_asset(&self, uint id)
{
	foreach (asset : self.assets)
	{
		if (asset.id == id) return asset;
	}
	return NOT_FOUND~;
}

excuse NOT_FOUND;

<*
 Takes ownership of `bytes`, unless an identical picture is already on the board. In
 that case `bytes` is freed and the existing asset is returned.
*>
fn Asset* Board.add_asset(&self, char[] bytes, String extension, int width, int height, ulong hash)
{
	foreach (asset : self.assets)
	{
		if (asset.hash == hash && asset.bytes.len == bytes.len)
		{
			free(bytes.ptr);
			return asset;
		}
	}
	Asset* asset = mem::new(Asset);
	asset.id = self.next_id++;
	asset.bytes = bytes;
	asset.extension = extension.copy(mem);
	asset.width = width;
	asset.height = height;
	asset.hash = hash;
	self.assets.push(asset);
	return asset;
}

// Records the state of an item once per action, the first time it is about to change.
fn void Board.note(&self, Item* item)
{
	if (self.pending_index.has_key(item.id)) return;
	item.retain();
	self.pending_index[item.id] = (int)self.pending.len();
	self.pending.push({ .id = item.id, .had_before = true, .before = *item });
}

<*
 Call before changing fields of an item, so the change can be undone.
*>
fn Item* Board.touch(&self, Item* item)
{
	self.note(item);
	return item;
}

<*
 Adds an item, taking over the caller's reference to its ink or text. A zero id or z
 means "assign a new one"; z-assigned items land on top.
*>
fn Item* Board.add(&self, Item value)
{
	assert(!value.id || !self.by_id.has_key(value.id), "item ids must be unique");
	Item* item = mem::new(Item);
	*item = value;
	if (!item.id) item.id = self.next_id++;
	if (item.id >= self.next_id) self.next_id = item.id + 1;
	if (!item.z) item.z = ++self.z_top;
	if (item.z > self.z_top) self.z_top = item.z;
	if (item.z < self.z_bottom) self.z_bottom = item.z;
	self.items.push(item);
	self.by_id[item.id] = item;
	self.needs_sync = true;
	if (!self.pending_index.has_key(item.id))
	{
		self.pending_index[item.id] = (int)self.pending.len();
		self.pending.push({ .id = item.id, .had_before = false });
	}
	return item;
}

fn void Board.remove(&self, Item* item)
{
	if (item.dead) return;
	self.note(item);
	self.drop_live(item);
}

fn void Board.drop_live(&self, Item* item)
{
	item.dead = true;
	item.release();
	self.by_id.remove(item.id);
	self.needs_sync = true;
}

fn void Board.bring_to_front(&self, Item* item)
{
	self.touch(item).z = ++self.z_top;
	self.needs_sync = true;
}

fn void Board.send_to_back(&self, Item* item)
{
	self.touch(item).z = --self.z_bottom;
	self.needs_sync = true;
}

fn int order_items(Item** a, Item** b) @local
{
	if ((*a).z != (*b).z) return (*a).z < (*b).z ? -1 : 1;
	if ((*a).id != (*b).id) return (*a).id < (*b).id ? -1 : 1;
	return 0;
}

<*
 Drops removed items and restores z-order. Item pointers stay valid until this runs, so
 callers can remove items while walking the list.
*>
fn void Board.sync(&self)
{
	if (!self.needs_sync) return;
	self.needs_sync = false;
	sz out = 0;
	foreach (i, item : self.items)
	{
		if (item.dead)
		{
			free(item);
			continue;
		}
		self.items[out++] = item;
	}
	while (self.items.len() > out) (void)self.items.pop();
	Item*[] view = self.items.array_view();
	// New strokes land on top, so this nearly always finds nothing to do. When it does
	// sort it must be mergesort: quicksort degrades to O(n^2) on data this ordered.
	bool sorted = true;
	for (sz i = 1; i < view.len && sorted; i++) sorted = order_items(&view[i - 1], &view[i]) <= 0;
	if (sorted) return;
	@pool()
	{
		mergesort(view, &order_items);
	};
}

fn bool same_state(Item* a, Item* b) @local
{
	return a.pos == b.pos && a.scale == b.scale && a.z == b.z && a.size == b.size
		&& a.color == b.color && a.fill == b.fill && a.parent == b.parent
		&& a.ink == b.ink;
}

<*
 Closes the current action. Everything touched since the last commit becomes a single
 undo step; an action that ended up changing nothing leaves no step behind.
*>
fn void Board.commit(&self)
{
	self.sync();
	if (self.pending.is_empty()) return;
	Step step;
	step.init(mem);
	foreach (&c : self.pending)
	{
		Item*? current = self.by_id.get(c.id);
		if (try current)
		{
			if (c.had_before && same_state(&c.before, current))
			{
				c.before.release();
				continue;
			}
			c.had_after = true;
			c.after = *current;
			c.after.retain();
		}
		else if (!c.had_before)
		{
			continue;
		}
		step.push(*c);
	}
	self.pending.clear();
	self.pending_index.clear();
	if (step.is_empty())
	{
		step.free();
		return;
	}
	self.undo_steps.push(step);
	clear_steps(&self.redo_steps);
	if (self.undo_steps.len() > MAX_UNDO)
	{
		Step oldest = self.undo_steps[0];
		free_step(&oldest);
		self.undo_steps.remove_at(0);
	}
	self.revision++;
}

fn void Board.restore(&self, uint id, bool exists, Item* state)
{
	Item*? current = self.by_id.get(id);
	if (!exists)
	{
		if (try current) self.drop_live(current);
		return;
	}
	if (try current)
	{
		current.release();
		*current = *state;
		current.retain();
	}
	else
	{
		Item* item = mem::new(Item);
		*item = *state;
		item.retain();
		self.items.push(item);
		self.by_id[item.id] = item;
	}
	self.needs_sync = true;
}

fn bool Board.undo(&self)
{
	self.commit();
	if (self.undo_steps.is_empty()) return false;
	Step step = self.undo_steps.pop()!!;
	for (sz i = step.len(); i > 0; i--)
	{
		Change* c = step.get_ref(i - 1);
		self.restore(c.id, c.had_before, &c.before);
	}
	self.redo_steps.push(step);
	self.sync();
	self.revision++;
	return true;
}

fn bool Board.redo(&self)
{
	self.commit();
	if (self.redo_steps.is_empty()) return false;
	Step step = self.redo_steps.pop()!!;
	foreach (&c : step) self.restore(c.id, c.had_after, &c.after);
	self.undo_steps.push(step);
	self.sync();
	self.revision++;
	return true;
}

<*
 Drops the history. Used after loading a file, which should not be undoable.
*>
fn void Board.forget_history(&self)
{
	self.sync();
	foreach (&c : self.pending)
	{
		if (c.had_before) c.before.release();
	}
	self.pending.clear();
	self.pending_index.clear();
	clear_steps(&self.undo_steps);
	clear_steps(&self.redo_steps);
}

<*
 The topmost item under a world point, optionally restricted to pictures.
*>
fn Item*? Board.item_at(&self, DVec2 p, double tolerance, bool images_only = false)
{
	for (sz i = self.items.len(); i > 0; i--)
	{
		Item* item = self.items[i - 1];
		if (item.dead) continue;
		if (images_only && item.kind != IMAGE) continue;
		if (item.hit(p, tolerance)) return item;
	}
	return NOT_FOUND~;
}

<*
 Bounds of everything on the board.
*>
fn DRect? Board.extent(&self)
{
	DRect? box = NOT_FOUND~;
	foreach (item : self.items)
	{
		if (item.dead) continue;
		DRect b = item.bounds();
		if (try known = box)
		{
			box = known.merge(b);
		}
		else
		{
			box = b;
		}
	}
	return box;
}
