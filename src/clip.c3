// Reads pictures and copied files from the X11 clipboard. raylib can only do this on
// Windows, and GLFW only hands over text. A separate display connection is used so that
// these events never mix with GLFW's own.
module tabla::clip;
import std::collections::list, std::time::clock;

alias XWindow = CULong;
alias Atom = CULong;

const CLong PROPERTY_CHANGE_MASK = 1 << 22;
const int SELECTION_NOTIFY = 31;
const int PROPERTY_NOTIFY = 28;
const int PROPERTY_NEW_VALUE = 0;
const short POLL_IN = 1;
const long TIMEOUT_NANOS = 1_500_000_000;
const CLong MAX_PROPERTY_LONGS = 0x1000000;

extern fn void* x_open_display(ZString name) @cname("XOpenDisplay");
extern fn CInt x_close_display(void* display) @cname("XCloseDisplay");
extern fn XWindow x_default_root_window(void* display) @cname("XDefaultRootWindow");
extern fn XWindow x_create_simple_window(void* display, XWindow parent, CInt x, CInt y, CUInt width, CUInt height, CUInt border, CULong border_pixel, CULong background) @cname("XCreateSimpleWindow");
extern fn Atom x_intern_atom(void* display, ZString name, CInt only_if_exists) @cname("XInternAtom");
extern fn XWindow x_get_selection_owner(void* display, Atom selection) @cname("XGetSelectionOwner");
extern fn CInt x_convert_selection(void* display, Atom selection, Atom target, Atom property, XWindow requestor, CULong time) @cname("XConvertSelection");
extern fn CInt x_select_input(void* display, XWindow window, CLong mask) @cname("XSelectInput");
extern fn CInt x_pending(void* display) @cname("XPending");
extern fn CInt x_next_event(void* display, XEvent* event) @cname("XNextEvent");
extern fn CInt x_flush(void* display) @cname("XFlush");
extern fn CInt x_connection_number(void* display) @cname("XConnectionNumber");
extern fn CInt x_get_window_property(void* display, XWindow window, Atom property, CLong offset, CLong length, CInt delete, Atom requested_type, Atom* actual_type, CInt* actual_format, CULong* item_count, CULong* bytes_after, char** data) @cname("XGetWindowProperty");
extern fn CInt x_free(void* data) @cname("XFree");
extern fn CInt poll(PollFd* fds, CULong count, CInt timeout_ms);
extern fn XWindow own_x11_window(void* glfw_window) @cname("glfwGetX11Window");

struct PollFd
{
	CInt fd;
	short events;
	short revents;
}

// The two members of the C XEvent union that are read here, padded to its size.
union XEvent
{
	CInt type;
	struct selection
	{
		CInt type;
		CULong serial;
		CInt send_event;
		void* display;
		XWindow requestor;
		Atom selection;
		Atom target;
		Atom property;
		CULong time;
	}
	struct property
	{
		CInt type;
		CULong serial;
		CInt send_event;
		void* display;
		XWindow window;
		Atom atom;
		CULong time;
		CInt state;
	}
	CLong[24] pad;
}

struct Session
{
	void* display;
	XWindow window;
	Atom selection;
	Atom property;
	Atom incr;
}

excuse NO_CLIPBOARD, TIMED_OUT, NO_DATA;

enum ContentKind
{
	NOTHING,
	PICTURE,
	FILES,
	OTHER, // something else is there, most likely text
}

struct Content
{
	ContentKind kind;
	List{char} bytes;
	String extension; // for pictures; points to static data
}

fn void Content.free(&self) => self.bytes.free();

fn bool? wait_for_event(Session* s, int type, Clock started, XEvent* event) @local
{
	while (true)
	{
		while (x_pending(s.display))
		{
			x_next_event(s.display, event);
			if (event.type == type) return true;
		}
		if ((long)started.to_now() > TIMEOUT_NANOS) return TIMED_OUT~;
		PollFd fd = { .fd = x_connection_number(s.display), .events = POLL_IN };
		poll(&fd, 1, 50);
	}
}

fn sz append_property(Session* s, List{char}* out, Atom* type) @local
{
	CInt format;
	CULong count;
	CULong after;
	char* data;
	if (x_get_window_property(s.display, s.window, s.property, 0, MAX_PROPERTY_LONGS, 1, 0, type, &format, &count, &after, &data) != 0) return 0;
	defer if (data) x_free(data);
	if (!data || !count) return 0;
	// Xlib returns format 32 data as an array of C longs.
	sz unit = format == 32 ? CLong::size : format / 8;
	out.push_all(data[:(sz)count * unit]);
	return (sz)count;
}

<*
 Fetches one target of the selection, following the INCR protocol that owners use for
 anything too large to go through a single window property.
*>
fn void? fetch(Session* s, Atom target, List{char}* out) @local
{
	Clock started = clock::now();
	XEvent event;
	x_convert_selection(s.display, s.selection, target, s.property, s.window, 0);
	x_flush(s.display);
	wait_for_event(s, SELECTION_NOTIFY, started, &event)!;
	if (!event.selection.property) return NO_DATA~;

	Atom type;
	append_property(s, out, &type);
	if (type != s.incr) return;

	out.clear();
	while (true)
	{
		wait_for_event(s, PROPERTY_NOTIFY, started, &event)!;
		if (event.property.atom != s.property || event.property.state != PROPERTY_NEW_VALUE) continue;
		if (!append_property(s, out, &type)) return;
		started = clock::now();
		x_flush(s.display);
	}
}

struct Format @local
{
	ZString atom_name;
	String extension;
	ContentKind kind;
}

const Format[*] FORMATS @local = {
	{ "image/png", ".png", PICTURE },
	{ "image/jpeg", ".jpg", PICTURE },
	{ "image/bmp", ".bmp", PICTURE },
	{ "image/x-bmp", ".bmp", PICTURE },
	{ "image/gif", ".gif", PICTURE },
	{ "text/uri-list", "", FILES },
};

<*
 Looks for a picture or files on the given selection.
*>
fn Content read(void* own_window, ZString selection_name = "CLIPBOARD")
{
	Content content;
	content.bytes.init(mem);
	void* display = x_open_display(null);
	if (!display) return content;
	defer x_close_display(display);

	Session s = { .display = display };
	s.selection = x_intern_atom(display, selection_name, 0);
	s.property = x_intern_atom(display, "TABLA_CLIP", 0);
	s.incr = x_intern_atom(display, "INCR", 0);
	XWindow owner = x_get_selection_owner(display, s.selection);
	if (!owner) return content;
	// Asking ourselves would deadlock: the answer needs the loop that is waiting here.
	if (owner == own_x11_window(own_window))
	{
		content.kind = OTHER;
		return content;
	}

	s.window = x_create_simple_window(display, x_default_root_window(display), 0, 0, 1, 1, 0, 0, 0);
	x_select_input(display, s.window, PROPERTY_CHANGE_MASK);

	List{char} targets;
	targets.init(mem);
	defer targets.free();
	if (catch fetch(&s, x_intern_atom(display, "TARGETS", 0), &targets)) return content;
	Atom[] offered = ((Atom*)targets.array_view().ptr)[:targets.len() / Atom::size];

	content.kind = OTHER;
	foreach (format : FORMATS)
	{
		Atom wanted = x_intern_atom(display, format.atom_name, 0);
		bool found = false;
		foreach (atom : offered)
		{
			if (atom == wanted) found = true;
		}
		if (!found) continue;
		if (catch fetch(&s, wanted, &content.bytes))
		{
			content.bytes.clear();
			continue;
		}
		if (content.bytes.is_empty()) continue;
		content.kind = format.kind;
		content.extension = format.extension;
		break;
	}
	return content;
}

<*
 Turns a text/uri-list into local file paths, allocated with the temp allocator.
*>
fn String[] parse_uri_list(String list)
{
	List{String} paths;
	paths.tinit();
	foreach (line : list.tsplit("\n"))
	{
		String uri = line.trim();
		if (!uri.starts_with("file://")) continue;
		uri = uri[7..];
		// file://host/path: skip the host, which is usually empty.
		sz? slash = uri.index_of_char('/');
		if (catch slash) continue;
		uri = uri[slash..];
		char[] decoded = mem::talloc_array(char, uri.len);
		sz length = 0;
		for (sz i = 0; i < uri.len; i++)
		{
			char c = uri[i];
			if (c == '%' && i + 2 < uri.len)
			{
				int high = hex_value(uri[i + 1]);
				int low = hex_value(uri[i + 2]);
				if (high >= 0 && low >= 0)
				{
					c = (char)(high * 16 + low);
					i += 2;
				}
			}
			decoded[length++] = c;
		}
		paths.push((String)decoded[:length]);
	}
	return paths.array_view();
}

fn int hex_value(char c) @local
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}
