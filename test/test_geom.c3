module tabla::test_geom;
import tabla::geom, std::collections::list, std::math;

fn void flatten_keeps_endpoints_and_adds_points_on_curves() @test
{
	InkPoint[*] src = { { 0, 0, 2 }, { 10, 0, 2 }, { 10, 10, 2 }, { 0, 10, 2 } };
	List{InkPoint} out;
	defer out.free();
	geom::flatten(&src, true, &out);
	assert(out.len() > src.len, "curves should gain points");
	test::eq(out[0].x, 0.0f);
	test::eq(out[out.len() - 1].y, 10.0f);
}

fn void flatten_without_smoothing_is_a_copy() @test
{
	InkPoint[*] src = { { 0, 0, 2 }, { 10, 0, 2 }, { 10, 10, 2 } };
	List{InkPoint} out;
	defer out.free();
	geom::flatten(&src, false, &out);
	test::eq(out.len(), 3);
}

fn void tessellate_makes_triangles_for_every_tip() @test
{
	InkPoint[*] src = { { 0, 0, 4 }, { 20, 0, 4 }, { 25, 15, 4 }, { 0, 30, 4 } };
	List{Vec2} out;
	List{InkPoint} scratch;
	defer out.free();
	defer scratch.free();
	foreach (tip : Tip::values)
	{
		geom::tessellate(&src, true, tip, &out, &scratch);
		assert(out.len() > 0, "expected triangles");
		test::eq(out.len() % 3, 0);
	}
}

fn void single_point_becomes_a_dot() @test
{
	InkPoint[*] src = { { 5, 5, 8 } };
	List{Vec2} out;
	List{InkPoint} scratch;
	defer out.free();
	defer scratch.free();
	geom::tessellate(&src, true, ROUND, &out, &scratch);
	test::eq(out.len(), geom::DISC_SEGMENTS * 3);
}

fn void tessellate_stays_inside_width_on_a_sharp_reversal() @test
{
	// A hairpin must not produce a mitre spike far beyond the stroke.
	InkPoint[*] src = { { 0, 0, 4 }, { 50, 0, 4 }, { 0, 0.5f, 4 } };
	List{Vec2} out;
	List{InkPoint} scratch;
	defer out.free();
	defer scratch.free();
	geom::tessellate(&src, false, ROUND, &out, &scratch);
	foreach (v : out)
	{
		assert(v.x < 53 && v.x > -3, "vertex escaped the stroke at %f", v.x);
		assert(v.y < 5 && v.y > -5, "vertex escaped the stroke at %f", v.y);
	}
}

fn void free_runs(List{InkPoint[]}* runs) @local
{
	foreach (run : runs) free(run.ptr);
	runs.free();
}

fn void eraser_splits_a_line_in_two() @test
{
	InkPoint[*] src = { { 0, 0, 2 }, { 100, 0, 2 } };
	List{InkPoint[]} runs;
	defer free_runs(&runs);
	bool hit = geom::erase_capsule(&src, { 50, 0 }, { 50, 0 }, 5, &runs);
	assert(hit, "the line passes through the eraser");
	test::eq(runs.len(), 2);
	float left_end = runs[0][^1].x;
	float right_start = runs[1][0].x;
	assert(left_end < 45 && left_end > 35, "left cut at %f", left_end);
	assert(right_start > 55 && right_start < 65, "right cut at %f", right_start);
}

fn void eraser_misses_a_distant_line() @test
{
	InkPoint[*] src = { { 0, 0, 2 }, { 100, 0, 2 } };
	List{InkPoint[]} runs;
	defer free_runs(&runs);
	assert(!geom::erase_capsule(&src, { 50, 40 }, { 50, 40 }, 5, &runs), "too far away");
	test::eq(runs.len(), 0);
}

fn void eraser_can_remove_a_stroke_entirely() @test
{
	InkPoint[*] src = { { 0, 0, 2 }, { 1, 0, 2 }, { 2, 0, 2 } };
	List{InkPoint[]} runs;
	defer free_runs(&runs);
	assert(geom::erase_capsule(&src, { 1, 0 }, { 1, 0 }, 10, &runs), "fully covered");
	test::eq(runs.len(), 0);
}

fn void eraser_keeps_the_stored_points_outside_the_cut() @test
{
	InkPoint[*] src = { { 0, 0, 2 }, { 10, 0, 2 }, { 20, 0, 2 }, { 30, 0, 2 }, { 40, 0, 2 } };
	List{InkPoint[]} runs;
	defer free_runs(&runs);
	assert(geom::erase_capsule(&src, { 35, 0 }, { 35, 0 }, 1, &runs), "cuts the last segment");
	test::eq(runs.len(), 2);
	test::eq(runs[0][0].x, 0.0f);
	test::eq(runs[1][^1].x, 40.0f);
}

fn void rect_merge_and_contains() @test
{
	DRect a = geom::rect_of({ 10, 10 }, { 0, 0 });
	DRect b = geom::rect_of({ 5, 5 }, { 20, 20 });
	DRect m = a.merge(b);
	test::eq(m.lo.x, 0.0);
	test::eq(m.hi.x, 20.0);
	assert(a.contains({ 5, 5 }), "inside");
	assert(!a.contains({ 15, 5 }), "outside");
	assert(a.overlaps(b), "overlap");
}

fn void plain_data_has_no_orientation() @test
{
	char[*] png = { 0x89, 'P', 'N', 'G', 0, 0, 0, 0 };
	test::eq(geom::jpeg_orientation(&png), 1);
	test::eq(geom::jpeg_orientation({}), 1);
}

fn void reads_orientation_from_exif() @test
{
	// SOI, APP1 with a little-endian TIFF holding one tag: orientation 6.
	char[*] jpeg = {
		0xFF, 0xD8, 0xFF, 0xE1, 0, 34, 'E', 'x', 'i', 'f', 0, 0,
		'I', 'I', 42, 0, 8, 0, 0, 0,
		1, 0,
		0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0,
		0, 0, 0, 0
	};
	test::eq(geom::jpeg_orientation(&jpeg), 6);
}

fn void truncated_exif_is_harmless() @test
{
	char[*] jpeg = { 0xFF, 0xD8, 0xFF, 0xE1, 0, 200, 'E', 'x', 'i', 'f', 0, 0, 'I', 'I' };
	test::eq(geom::jpeg_orientation(&jpeg), 1);
}
