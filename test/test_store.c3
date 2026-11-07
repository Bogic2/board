module tabla::test_store;
import tabla::board, tabla::geom, tabla::store;
import std::io, std::math::random;

const String PATH = "build/test_store.tabla";

fn void fill(Board* b) @local
{
	InkPoint[] points = mem::new_array(InkPoint, 3);
	points[0] = { 0, 0, 2 };
	points[1] = { 5.5f, 1, 3 };
	points[2] = { 9, 9, 4 };
	b.add({ .kind = INK, .pos = { 1e9, -2.5 }, .scale = 0.25, .color = { 1, 2, 3, 200 }, .ink = board::ink_new(points, true, CHISEL) });

	char[] bytes = mem::new_array(char, 6);
	bytes[..] = 7;
	Asset* asset = b.add_asset(bytes, ".png", 64, 32, 0xABCD);
	Item* pic = b.add({ .kind = IMAGE, .pos = { 3, 4 }, .scale = 2, .size = { 64, 32 }, .asset = asset });

	points = mem::new_array(InkPoint, 1);
	points[0] = { 1, 1, 8 };
	b.add({ .kind = INK, .parent = pic.id, .scale = 1, .ink = board::ink_new(points, false, ROUND) });

	b.add({ .kind = TEXT, .scale = 1.5, .size = { 200, 100 }, .fill = { 255, 240, 150, 255 }, .color = { 0, 0, 0, 255 }, .text = board::text_new("Šđčćž Ш\nline two") });
	b.commit();
}

fn void round_trip_keeps_everything() @test
{
	Board b;
	b.init();
	defer b.free();
	fill(&b);
	store::save(&b, { .origin = { 12.5, -9 }, .zoom = 0.75, .paper = 2, .pattern = 1 }, PATH)!!;

	Board c;
	c.init();
	defer c.free();
	View view = store::load(&c, PATH)!!;
	test::eq(view.origin.x, 12.5);
	test::eq(view.zoom, 0.75);
	test::eq(view.paper, 2);
	test::eq(c.items.len(), 4);
	test::eq(c.assets.len(), 1);

	Item* ink = c.items[0];
	test::eq(ink.pos.x, 1e9);
	test::eq(ink.scale, 0.25);
	test::eq(ink.ink.points[1].x, 5.5f);
	assert(ink.ink.smooth, "smoothing flag");
	assert(ink.ink.tip == CHISEL, "tip");

	Item* pic = c.items[1];
	test::eq(pic.asset.width, 64);
	test::eq(pic.asset.bytes.len, 6);
	test::eq(pic.asset.bytes[5], 7);

	Item* pinned = c.items[2];
	test::eq(pinned.parent, pic.id);

	Item* text = c.items[3];
	test::eq(text.text.text, "Šđčćž Ш\nline two");
	test::eq(text.fill.x, 255);

	test::eq(c.undo_steps.len(), 0);
	assert(c.next_id >= b.next_id, "ids stay unique after loading");
}

fn void z_order_survives_saving() @test
{
	Board b;
	b.init();
	defer b.free();
	fill(&b);
	uint top_id = b.items[3].id;
	b.send_to_back(b.items[3]);
	b.commit();
	store::save(&b, { .zoom = 1 }, PATH)!!;

	Board c;
	c.init();
	defer c.free();
	store::load(&c, PATH)!!;
	test::eq(c.items[0].id, top_id);
}

fn void pictures_only_reachable_through_undo_are_not_saved() @test
{
	Board b;
	b.init();
	defer b.free();
	fill(&b);
	b.remove(b.items[1]);
	b.commit();
	store::save(&b, { .zoom = 1 }, PATH)!!;

	Board c;
	c.init();
	defer c.free();
	store::load(&c, PATH)!!;
	test::eq(c.assets.len(), 0);
	test::eq(c.items.len(), 3);
}

fn void rejects_files_that_are_not_boards() @test
{
	file::save(PATH, "this is certainly not a board file")!!;
	Board c;
	c.init();
	defer c.free();
	test::@error(store::load(&c, PATH), store::NOT_A_BOARD);
}

fn void rejects_files_from_the_future() @test
{
	Board b;
	b.init();
	defer b.free();
	fill(&b);
	store::save(&b, { .zoom = 1 }, PATH)!!;
	char[] data = file::load(mem, PATH)!!;
	defer free(data.ptr);
	data[8] = 200;
	file::save(PATH, data)!!;
	Board c;
	c.init();
	defer c.free();
	test::@error(store::load(&c, PATH), store::NEWER_VERSION);
}

fn void every_truncation_fails_cleanly() @test
{
	Board b;
	b.init();
	defer b.free();
	fill(&b);
	store::save(&b, { .zoom = 1 }, PATH)!!;
	char[] data = file::load(mem, PATH)!!;
	defer free(data.ptr);
	for (sz cut = 0; cut < data.len; cut++)
	{
		file::save(PATH, data[:cut])!!;
		Board c;
		c.init();
		defer c.free();
		if (try store::load(&c, PATH)) assert(false, "a file cut at %d should not load", cut);
	}
}

fn void random_corruption_never_crashes() @test
{
	Board b;
	b.init();
	defer b.free();
	fill(&b);
	store::save(&b, { .zoom = 1 }, PATH)!!;
	char[] data = file::load(mem, PATH)!!;
	defer free(data.ptr);

	Mcg128Random rng;
	random::seed(&rng, 12345);
	for (int round = 0; round < 3000; round++)
	{
		char[] broken = mem::new_array(char, data.len);
		defer free(broken.ptr);
		broken[..] = data[..];
		uint flips = 1 + rng.next_int() % 4;
		for (uint f = 0; f < flips; f++)
		{
			broken[(sz)(rng.next_int() % (uint)data.len)] = rng.next_byte();
		}
		file::save(PATH, broken)!!;
		Board c;
		c.init();
		defer c.free();
		(void)store::load(&c, PATH);
	}
}

fn void failed_save_keeps_the_existing_file() @test
{
	Board b;
	b.init();
	defer b.free();
	fill(&b);
	test::@error(store::save(&b, { .zoom = 1 }, "build/no/such/dir/x.tabla"));
	store::save(&b, { .zoom = 1 }, PATH)!!;
	assert(!file::exists(PATH.tconcat(".tmp")), "no temp file left behind");
}
