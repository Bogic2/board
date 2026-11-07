module tabla::test_board;
import tabla::board, tabla::geom, std::collections::list;

fn Item line_item(float length = 10) @local
{
	InkPoint[] points = mem::new_array(InkPoint, 2);
	points[0] = { 0, 0, 2 };
	points[1] = { length, 0, 2 };
	return { .kind = INK, .scale = 1, .color = { 0, 0, 0, 255 }, .ink = board::ink_new(points, false, ROUND) };
}

fn Board fresh() @local
{
	Board b;
	b.init();
	return b;
}

fn void undo_redo_add() @test
{
	Board b = fresh();
	defer b.free();
	b.add(line_item());
	b.commit();
	test::eq(b.items.len(), 1);
	assert(b.undo(), "one step to undo");
	test::eq(b.items.len(), 0);
	assert(b.redo(), "one step to redo");
	test::eq(b.items.len(), 1);
}

fn void undo_restores_position_and_groups_a_whole_drag() @test
{
	Board b = fresh();
	defer b.free();
	Item* item = b.add(line_item());
	uint id = item.id;
	b.commit();
	for (int i = 0; i < 10; i++) b.touch(item).pos.x += 5;
	b.commit();
	test::eq(item.pos.x, 50.0);
	assert(b.undo(), "the drag is a single step");
	test::eq(b.get(id)!!.pos.x, 0.0);
	test::eq(b.undo_steps.len(), 1);
}

fn void commit_without_real_change_leaves_no_step() @test
{
	Board b = fresh();
	defer b.free();
	Item* item = b.add(line_item());
	b.commit();
	b.touch(item).pos.x += 5;
	b.touch(item).pos.x -= 5;
	ulong revision = b.revision;
	b.commit();
	test::eq(b.undo_steps.len(), 1);
	test::eq(b.revision, revision);
}

fn void undo_brings_back_a_removed_item_with_its_geometry() @test
{
	Board b = fresh();
	defer b.free();
	Item* item = b.add(line_item(42));
	uint id = item.id;
	b.commit();
	b.remove(item);
	b.commit();
	test::eq(b.items.len(), 0);
	assert(b.undo(), "undo the removal");
	Item* back = b.get(id)!!;
	test::eq(back.ink.points[1].x, 42.0f);
}

fn void item_added_and_removed_in_one_action_leaves_no_trace() @test
{
	Board b = fresh();
	defer b.free();
	b.remove(b.add(line_item()));
	b.commit();
	test::eq(b.items.len(), 0);
	test::eq(b.undo_steps.len(), 0);
}

fn void new_action_clears_redo() @test
{
	Board b = fresh();
	defer b.free();
	b.add(line_item());
	b.commit();
	b.undo();
	b.add(line_item());
	b.commit();
	assert(!b.redo(), "redo history is gone after a new action");
}

fn void z_order_changes_are_undoable() @test
{
	Board b = fresh();
	defer b.free();
	Item* first = b.add(line_item());
	Item* second = b.add(line_item());
	uint first_id = first.id;
	uint second_id = second.id;
	b.commit();
	test::eq(b.items[1].id, second_id);
	b.bring_to_front(first);
	b.commit();
	test::eq(b.items[1].id, first_id);
	b.undo();
	test::eq(b.items[1].id, second_id);
	b.send_to_back(b.get(second_id)!!);
	b.commit();
	test::eq(b.items[0].id, second_id);
}

fn void geometry_is_shared_until_the_last_reference_goes() @test
{
	Board b = fresh();
	defer b.free();
	Item* item = b.add(line_item());
	Ink* ink = item.ink;
	b.commit();
	test::eq(ink.refs, 2); // the live item and the undo step
	b.remove(item);
	b.commit();
	test::eq(ink.refs, 2); // the two undo snapshots, no live item
}

fn void undo_history_is_bounded() @test
{
	Board b = fresh();
	defer b.free();
	Item* item = b.add(line_item());
	b.commit();
	for (int i = 0; i < board::MAX_UNDO + 40; i++)
	{
		b.touch(item).pos.x += 1;
		b.commit();
	}
	test::eq(b.undo_steps.len(), board::MAX_UNDO);
}

fn void hit_testing_follows_the_stroke_not_its_box() @test
{
	InkPoint[] points = mem::new_array(InkPoint, 3);
	points[0] = { 0, 0, 2 };
	points[1] = { 100, 0, 2 };
	points[2] = { 100, 100, 2 };
	Item item = { .kind = INK, .scale = 1, .ink = board::ink_new(points, false, ROUND) };
	defer item.release();
	assert(item.hit({ 50, 0 }, 1), "on the first leg");
	assert(item.hit({ 100, 50 }, 1), "on the second leg");
	assert(!item.hit({ 40, 60 }, 1), "inside the box, off the ink");
}

fn void hit_testing_respects_position_and_scale() @test
{
	Item item = line_item(10);
	defer item.release();
	item.pos = { 1000, 2000 };
	item.scale = 3;
	assert(item.hit({ 1029, 2000 }, 0.5), "scaled end of the line");
	assert(!item.hit({ 1009, 2010 }, 0.5), "off the line");
}

fn void marquee_needs_a_point_of_the_ink() @test
{
	InkPoint[] points = mem::new_array(InkPoint, 2);
	points[0] = { 0, 0, 2 };
	points[1] = { 100, 100, 2 };
	Item item = { .kind = INK, .scale = 1, .ink = board::ink_new(points, false, ROUND) };
	defer item.release();
	assert(item.in_rect(geom::rect_of({ -5, -5 }, { 5, 5 })), "covers an end");
	assert(!item.in_rect(geom::rect_of({ 60, 0 }, { 80, 20 })), "inside the box only");
}

fn void identical_pictures_share_an_asset() @test
{
	Board b = fresh();
	defer b.free();
	char[] one = mem::new_array(char, 4);
	char[] two = mem::new_array(char, 4);
	Asset* a = b.add_asset(one, ".png", 1, 1, 77);
	Asset* c = b.add_asset(two, ".png", 1, 1, 77);
	assert(a == c, "same content, same asset");
	test::eq(b.assets.len(), 1);
}

fn void top_most_item_wins() @test
{
	Board b = fresh();
	defer b.free();
	b.add(line_item());
	Item* top = b.add(line_item());
	uint top_id = top.id;
	b.commit();
	test::eq(b.item_at({ 5, 0 }, 1)!!.id, top_id);
}

fn void board_survives_the_end_of_a_temp_pool() @test
{
	// Regression: a default-initialised List lives in the temp allocator, so a first
	// push inside @pool used to leave the board pointing at freed memory.
	Board b = fresh();
	defer b.free();
	@pool()
	{
		b.add(line_item(7));
		b.add_asset(mem::new_array(char, 4), ".png", 1, 1, 5);
		b.commit();
	};
	@pool()
	{
		char[] noise = mem::talloc_array(char, 1 << 16);
		noise[..] = 0xEE;
	};
	test::eq(b.items.len(), 1);
	test::eq(b.items[0].ink.points[1].x, 7.0f);
	test::eq(b.assets.len(), 1);
	test::eq(b.assets[0].width, 1);
	assert(b.undo(), "the undo step survived too");
	test::eq(b.items.len(), 0);
}

fn void order_is_restored_after_undo_on_a_big_board() @test
{
	Board b = fresh();
	defer b.free();
	Item* first = b.add(line_item());
	uint first_id = first.id;
	for (int i = 0; i < 3000; i++) b.add(line_item());
	b.commit();
	b.remove(b.get(first_id)!!);
	b.commit();
	b.undo();
	test::eq(b.items[0].id, first_id);
	for (sz i = 1; i < b.items.len(); i++)
	{
		assert(b.items[i - 1].z < b.items[i].z, "items out of order at %d", i);
	}
}

fn void adopting_a_picture_copies_it_once() @test
{
	Board source = fresh();
	defer source.free();
	Board target = fresh();
	defer target.free();
	char[] bytes = mem::new_array(char, 3);
	bytes[0] = 7;
	Asset* original = source.add_asset(bytes, ".png", 4, 5, 99);

	Asset* copy = target.adopt_asset(original);
	assert(copy != original && copy.bytes.ptr != original.bytes.ptr);
	assert(copy.bytes[0] == 7 && copy.extension == ".png");
	assert(copy.width == 4 && copy.height == 5 && copy.hash == 99);
	assert(copy.state == UNLOADED);

	assert(target.adopt_asset(original) == copy);
	assert(source.adopt_asset(original) == original);
	assert(target.assets.len() == 1 && source.assets.len() == 1);
}
