// Tabla: a blank page that never runs out of room.
module tabla;
import tabla::app, tabla::input, tabla::clip, raylib55::rl;
import std::io, std::os::env, std::io::path;

// Boards opened without a file name all land here, so work is never lost by default.
fn String default_board_path() @local
{
	String dir;
	if (try data = env::tget_var("XDG_DATA_HOME"))
	{
		dir = data.tconcat("/tabla");
	}
	else
	{
		dir = (env::tget_var("HOME") ?? ".").tconcat("/.local/share/tabla");
	}
	(void)path::mkdir(dir, recursive: true);
	return dir.tconcat("/board.tabla");
}

fn int run_app(String path, RLConfigFlag extra_flags = (RLConfigFlag)0) @local
{
	rl::set_trace_log_level(ERROR);
	rl::set_config_flags(RLConfigFlag.MSAA_4X_HINT | RLConfigFlag.WINDOW_RESIZABLE | RLConfigFlag.VSYNC_HINT | extra_flags);
	rl::init_window(1360, 860, "Tabla");
	rl::set_window_min_size(860, 640);
	rl::set_exit_key(NONE);
	input::hook_pointer_trail();
	$if $feat(E2E):
		io::printfn("window %d", (ulong)clip::own_x11_window(rl::get_window_handle()));
		(void)io::stdout().flush();
	$endif

	App* a = mem::new(App);
	@pool()
	{
		a.init(path);
	};
	while (!rl::window_should_close() && !a.quit)
	{
		input::read(&a.input);
		a.frame();
	}
	a.shutdown();
	rl::close_window();
	return 0;
}

fn int main(String[] args)
{
	if (args.len > 1 && (args[1] == "--help" || args[1] == "-h"))
	{
		io::printn("usage: tabla [board.tabla]");
		io::printn("Without a file, tabla opens your default board.");
		return 0;
	}
	$if $feat(E2E):
		if (args.len > 2 && args[1] == "--e2e") return run_e2e(args[2]);
		if (args.len > 2 && args[1] == "--hidden") return run_app(args[2], RLConfigFlag.WINDOW_HIDDEN);
		if (args.len > 3 && args[1] == "--perf") return run_perf(args[2], args[3].to_int()!!);
	$endif
	@pool()
	{
		return run_app(args.len > 1 ? args[1] : default_board_path());
	};
}
