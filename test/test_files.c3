module tabla::test_files;
import tabla::app, tabla::clip;

fn void pictures_are_known_by_their_contents() @test
{
	char[16] data;
	data[0] = 0x89;
	data[1] = 'P';
	test::eq(app::sniff_picture(&data)!!, ".png");
	data[0] = 0xFF;
	data[1] = 0xD8;
	test::eq(app::sniff_picture(&data)!!, ".jpg");
	data = {};
	data[:3] = "GIF"[..];
	test::eq(app::sniff_picture(&data)!!, ".gif");
	data = {};
	data[:2] = "BM"[..];
	test::eq(app::sniff_picture(&data)!!, ".bmp");
	data = {};
	data[:4] = "qoif"[..];
	test::eq(app::sniff_picture(&data)!!, ".qoi");
}

fn void webp_and_unknown_data_are_told_apart() @test
{
	char[16] data;
	data[:4] = "RIFF"[..];
	data[8:4] = "WEBP"[..];
	test::@error(app::sniff_picture(&data), app::WEBP);
	data = {};
	test::@error(app::sniff_picture(&data), app::UNSUPPORTED);
	test::@error(app::sniff_picture({}), app::UNSUPPORTED);
}

fn void uri_lists_become_paths() @test => @pool()
{
	String[] paths = clip::parse_uri_list("file:///home/me/a%20b.png\r\n# a comment\nfile://host/tmp/%C5%A1.jpg\nhttp://example.com/x.png\n");
	test::eq(paths.len, 2);
	test::eq(paths[0], "/home/me/a b.png");
	test::eq(paths[1], "/tmp/š.jpg");
}

fn void broken_uri_escapes_are_kept_as_text() @test => @pool()
{
	String[] paths = clip::parse_uri_list("file:///a%zz%4");
	test::eq(paths.len, 1);
	test::eq(paths[0], "/a%zz%4");
}
