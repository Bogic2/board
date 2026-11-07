// Native file dialogs through zenity. The dialog runs on a thread: blocking the main
// loop would make the window manager report the app as frozen.
module tabla::dialog;
import std::thread, std::atomic, std::os::process, std::collections::list;

enum Request : char
{
	OPEN_BOARD,
	SAVE_BOARD,
	NEW_BOARD,
	ADD_IMAGES,
	EXPORT_PNG,
}

enum Outcome : int
{
	IDLE,
	RUNNING,
	CHOSEN,
	CANCELLED,
	UNAVAILABLE,
}

struct Job @local
{
	Request request;
	Thread thread;
	Atomic{Outcome} outcome;
	char[65536] buffer;
	String reply;
}

Job job @local;

fn int run_dialog(void* unused) @local
{
	const String BOARDS = "--file-filter=Tabla boards | *.tabla";
	const String IMAGES = "--file-filter=Images | *.png *.PNG *.jpg *.JPG *.jpeg *.JPEG *.bmp *.gif *.qoi";
	String[] command;
	switch (job.request)
	{
		case OPEN_BOARD:
			command = { "zenity", "--file-selection", "--title=Open board", BOARDS };
		case SAVE_BOARD:
			command = { "zenity", "--file-selection", "--save", "--confirm-overwrite", "--title=Save board as", "--filename=board.tabla", BOARDS };
		case NEW_BOARD:
			command = { "zenity", "--file-selection", "--save", "--confirm-overwrite", "--title=Create new board", "--filename=board.tabla", BOARDS };
		case ADD_IMAGES:
			command = { "zenity", "--file-selection", "--multiple", "--separator=\n", "--title=Add pictures", IMAGES };
		case EXPORT_PNG:
			command = { "zenity", "--file-selection", "--save", "--confirm-overwrite", "--title=Export as PNG", "--filename=board.png", "--file-filter=PNG | *.png" };
	}
	String? reply = process::run_capture_stdout(&job.buffer, command, INHERIT_ENV);
	if (catch reply)
	{
		job.outcome.store(UNAVAILABLE);
		return 0;
	}
	job.reply = reply.trim();
	job.outcome.store(job.reply.len ? CHOSEN : CANCELLED);
	return 0;
}

fn bool is_open() => job.outcome.load() == RUNNING;

fn bool start(Request request)
{
	if (is_open()) return false;
	job.request = request;
	job.outcome.store(RUNNING);
	if (catch job.thread.create(&run_dialog, null))
	{
		job.outcome.store(UNAVAILABLE);
		return false;
	}
	(void)job.thread.detach();
	return true;
}

<*
 Collects a finished dialog. `reply` stays valid until the next `start`.
*>
fn Outcome poll(Request* request, String* reply)
{
	Outcome outcome = job.outcome.load();
	if (outcome == RUNNING || outcome == IDLE) return IDLE;
	job.outcome.store(IDLE);
	*request = job.request;
	*reply = job.reply;
	return outcome;
}
