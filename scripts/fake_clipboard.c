// Test helper: owns an X11 selection and serves a file as image/png, using the INCR
// protocol when the file is large, as browsers and screenshot tools do. It uses its own
// selection name, so running the tests never touches the real clipboard.
//
//   cc scripts/fake_clipboard.c -lX11 -o build/fake_clipboard
//   build/fake_clipboard TABLA_TEST_SELECTION picture.png
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { CHUNK = 64 * 1024 };

int main(int argc, char **argv)
{
	if (argc != 3) return 2;
	FILE *f = fopen(argv[2], "rb");
	if (!f) return 2;
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	rewind(f);
	unsigned char *data = malloc(size);
	if (fread(data, 1, size, f) != (size_t)size) return 2;
	fclose(f);

	Display *d = XOpenDisplay(NULL);
	if (!d) return 2;
	Window w = XCreateSimpleWindow(d, DefaultRootWindow(d), 0, 0, 1, 1, 0, 0, 0);
	Atom selection = XInternAtom(d, argv[1], False);
	Atom targets = XInternAtom(d, "TARGETS", False);
	Atom png = XInternAtom(d, "image/png", False);
	Atom incr = XInternAtom(d, "INCR", False);
	XSetSelectionOwner(d, selection, w, CurrentTime);
	XSync(d, False);
	printf("ready\n");
	fflush(stdout);

	long sent = 0;
	Window transfer = None;
	Atom transfer_property = None;
	for (;;)
	{
		XEvent e;
		XNextEvent(d, &e);
		if (e.type == SelectionRequest)
		{
			XSelectionRequestEvent *r = &e.xselectionrequest;
			XEvent reply = { 0 };
			reply.xselection.type = SelectionNotify;
			reply.xselection.requestor = r->requestor;
			reply.xselection.selection = r->selection;
			reply.xselection.target = r->target;
			reply.xselection.time = r->time;
			reply.xselection.property = r->property;
			if (r->target == targets)
			{
				Atom offered[] = { targets, png };
				XChangeProperty(d, r->requestor, r->property, XA_ATOM, 32, PropModeReplace, (unsigned char *)offered, 2);
			}
			else if (r->target == png && size <= CHUNK)
			{
				XChangeProperty(d, r->requestor, r->property, png, 8, PropModeReplace, data, size);
			}
			else if (r->target == png)
			{
				long announced = size;
				XSelectInput(d, r->requestor, PropertyChangeMask);
				XChangeProperty(d, r->requestor, r->property, incr, 32, PropModeReplace, (unsigned char *)&announced, 1);
				transfer = r->requestor;
				transfer_property = r->property;
				sent = 0;
			}
			else
			{
				reply.xselection.property = None;
			}
			XSendEvent(d, r->requestor, False, 0, &reply);
			XFlush(d);
		}
		else if (e.type == PropertyNotify && e.xproperty.state == PropertyDelete && e.xproperty.window == transfer && e.xproperty.atom == transfer_property)
		{
			long part = size - sent < CHUNK ? size - sent : CHUNK;
			XChangeProperty(d, transfer, transfer_property, png, 8, PropModeReplace, data + sent, part);
			XFlush(d);
			sent += part;
			if (part == 0)
			{
				transfer = None;
				printf("sent %ld bytes in chunks\n", sent);
				fflush(stdout);
			}
		}
		else if (e.type == SelectionClear)
		{
			return 0;
		}
	}
}
