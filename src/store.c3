// The .tabla file: one self-contained file holding the view, every picture and every item.
module tabla::store;
import tabla::board, tabla::geom;
import std::io, std::collections::list, std::collections::map, libc;

excuse NOT_A_BOARD, NEWER_VERSION, CORRUPT;

const char[8] MAGIC = "TABLA\x1a\r\n";
const uint VERSION = 1;

extern fn CInt fsync(CInt fd) @local;

// Everything about a board that is not an item.
struct View
{
	DVec2 origin;
	double zoom;
	char paper;
	char pattern;
}

macro void put(List{char}* out, value) @local
{
	char* bytes = (char*)&value;
	out.push_all(bytes[:@sizeof(value)]);
}

fn void put_item(List{char}* out, Item* item) @local
{
	put(out, item.id);
	put(out, item.parent);
	put(out, item.z);
	put(out, item.pos.x);
	put(out, item.pos.y);
	put(out, item.scale);
	put(out, item.size.x);
	put(out, item.size.y);
	put(out, (char[4])item.color);
	put(out, (char[4])item.fill);
	put(out, (char)item.kind.ordinal);
	switch (item.kind)
	{
		case INK:
			put(out, (char)(item.ink.smooth ? 1 : 0));
			put(out, (char)item.ink.tip.ordinal);
			put(out, (uint)item.ink.points.len);
			out.push_all(((char*)item.ink.points.ptr)[:item.ink.points.len * InkPoint::size]);
		case IMAGE:
			put(out, item.asset.id);
		case TEXT:
			put(out, (uint)item.text.text.len);
			out.push_all((char[])item.text.text);
	}
}

<*
 Writes the board. The file is replaced atomically, so a crash or a full disk partway
 through can never damage the previous save.
*>
fn void? save(Board* board, View view, String path)
{
	board.sync();

	// History is not saved, so pictures only reachable through undo are left out.
	HashMap{uint, bool} used;
	used.init(mem);
	defer used.free();
	foreach (item : board.items)
	{
		if (item.kind == IMAGE) used[item.asset.id] = true;
	}

	List{char} head;
	head.init(mem);
	defer head.free();
	head.push_all(&MAGIC);
	put(&head, VERSION);
	put(&head, view.origin.x);
	put(&head, view.origin.y);
	put(&head, view.zoom);
	put(&head, view.paper);
	put(&head, view.pattern);
	put(&head, board.next_id);
	put(&head, (uint)used.len());

	List{char} body;
	body.init(mem);
	defer body.free();
	put(&body, (uint)board.items.len());
	foreach (item : board.items) put_item(&body, item);

	@pool()
	{
		String tmp = path.tconcat(".tmp");
		File f = file::open(tmp, "wb")!;
		defer catch
		{
			(void)f.close();
			(void)file::delete(tmp);
		}
		f.write(head.array_view())!;
		foreach (asset : board.assets)
		{
			if (!used.has_key(asset.id)) continue;
			List{char} entry;
			entry.init(mem);
			defer entry.free();
			put(&entry, asset.id);
			put(&entry, (int)asset.width);
			put(&entry, (int)asset.height);
			put(&entry, asset.hash);
			put(&entry, (uint)asset.extension.len);
			entry.push_all((char[])asset.extension);
			put(&entry, (ulong)asset.bytes.len);
			f.write(entry.array_view())!;
			f.write(asset.bytes)!;
		}
		f.write(body.array_view())!;
		f.flush()!;
		fsync((CInt)f.fd());
		f.close()!;
		if (libc::rename(tmp.zstr_tcopy(), path.zstr_tcopy()) != 0) return io::GENERAL_ERROR~;
	};
}

struct Reader @local
{
	char[] data;
	sz at;
}

macro Reader.get(&self, $Type)
{
	$Type? value = CORRUPT~;
	if (self.at + $Type::size <= self.data.len)
	{
		$Type known;
		mem::copy(&known, &self.data[self.at], $Type::size);
		self.at += $Type::size;
		value = known;
	}
	return value;
}

fn char[]? Reader.take(&self, sz count)
{
	if (count < 0 || count > self.data.len - self.at) return CORRUPT~;
	char[] slice = self.data[self.at:count];
	self.at += count;
	return slice;
}

fn bool finite(double v) @local => v == v && v > -1e300 && v < 1e300;

fn void? read_item(Reader* r, Board* board, HashMap{uint, Asset*}* assets) @local
{
	Item item;
	item.id = r.get(uint)!;
	item.parent = r.get(uint)!;
	item.z = r.get(long)!;
	item.pos.x = r.get(double)!;
	item.pos.y = r.get(double)!;
	item.scale = r.get(double)!;
	item.size.x = r.get(float)!;
	item.size.y = r.get(float)!;
	item.color = (Rgba)r.get(char[4])!;
	item.fill = (Rgba)r.get(char[4])!;
	char kind = r.get(char)!;
	if (!item.id || board.by_id.has_key(item.id)) return CORRUPT~;
	if (kind >= ItemKind::len) return CORRUPT~;
	if (!finite(item.pos.x) || !finite(item.pos.y) || !finite(item.size.x) || !finite(item.size.y)) return CORRUPT~;
	if (!finite(item.scale) || item.scale <= 0) return CORRUPT~;
	item.kind = ItemKind::from_ordinal(kind);
	switch (item.kind)
	{
		case INK:
			bool smooth = r.get(char)! != 0;
			char tip = r.get(char)!;
			uint count = r.get(uint)!;
			if (!count || tip >= Tip::len) return CORRUPT~;
			char[] raw = r.take((sz)count * InkPoint::size)!;
			InkPoint[] points = mem::new_array(InkPoint, count);
			mem::copy(points.ptr, raw.ptr, raw.len);
			foreach (p : points)
			{
				if (!finite(p.x) || !finite(p.y) || !finite(p.w))
				{
					free(points.ptr);
					return CORRUPT~;
				}
			}
			item.ink = board::ink_new(points, smooth, Tip::from_ordinal(tip));
		case IMAGE:
			Asset* asset = assets.get(r.get(uint)!) ?? CORRUPT~!;
			item.asset = asset;
		case TEXT:
			uint len = r.get(uint)!;
			item.text = board::text_new((String)r.take(len)!);
	}
	board.add(item);
}

<*
 Loads a board into a freshly initialised `board`. On failure the board may hold part
 of the file, so the caller should throw it away.
*>
fn View? load(Board* board, String path)
{
	char[] data = file::load(mem, path)!;
	defer free(data.ptr);
	Reader r = { .data = data };

	if (data.len < MAGIC.len || data[:MAGIC.len] != MAGIC[..]) return NOT_A_BOARD~;
	r.at = MAGIC.len;
	if (r.get(uint)! > VERSION) return NEWER_VERSION~;

	View view;
	view.origin.x = r.get(double)!;
	view.origin.y = r.get(double)!;
	view.zoom = r.get(double)!;
	view.paper = r.get(char)!;
	view.pattern = r.get(char)!;
	if (!finite(view.origin.x) || !finite(view.origin.y) || !finite(view.zoom) || view.zoom <= 0) return CORRUPT~;
	board.next_id = r.get(uint)!;
	if (!board.next_id) return CORRUPT~;

	HashMap{uint, Asset*} assets;
	assets.init(mem);
	defer assets.free();
	uint asset_count = r.get(uint)!;
	for (uint i = 0; i < asset_count; i++)
	{
		uint id = r.get(uint)!;
		int width = r.get(int)!;
		int height = r.get(int)!;
		ulong hash = r.get(ulong)!;
		uint ext_len = r.get(uint)!;
		if (ext_len > 16 || width <= 0 || height <= 0) return CORRUPT~;
		String extension = (String)r.take(ext_len)!;
		ulong size = r.get(ulong)!;
		if (size > (ulong)(data.len - r.at)) return CORRUPT~;
		char[] raw = r.take((sz)size)!;
		char[] bytes = mem::new_array(char, (sz)size);
		mem::copy(bytes.ptr, raw.ptr, raw.len);
		assets[id] = board.add_asset(bytes, extension, width, height, hash);
	}

	uint item_count = r.get(uint)!;
	for (uint i = 0; i < item_count; i++) read_item(&r, board, &assets)!;
	board.forget_history();
	return view;
}
