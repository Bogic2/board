// One frame of user input. The app only ever reads this struct, which is what lets the
// end-to-end tests drive the real application with a script.
module tabla::input;
import raylib55::rl, std::math;

const int KEY_COUNT = 350;
const int TRAIL_MAX = 512;

struct Sample
{
	Vec2 pos;
	double time;
}

struct Input
{
	Vec2 mouse;
	Vec2 delta;
	bool left_down;
	bool left_pressed;
	bool left_released;
	bool pan_pressed; // middle or right button
	bool pan_down;
	float wheel;
	bool ctrl;
	bool shift;
	bool[KEY_COUNT] pressed; // includes key repeat
	bool[KEY_COUNT] first_press; // does not
	bool[KEY_COUNT] down;
	bool[26] letters; // by the letter printed on the key, includes key repeat
	bool[26] first_letters; // does not
	int[32] chars;
	int char_count;
	Sample[TRAIL_MAX] trail; // every pointer position since the last frame
	int trail_count;
	double time;
	float dt;
	int width;
	int height;
}

alias CursorPosFn = fn void(void* window, double x, double y);

extern fn CursorPosFn glfw_set_cursor_pos_callback(void* window, CursorPosFn callback) @cname("glfwSetCursorPosCallback");
extern fn ZString glfw_get_key_name(int key, int scancode) @cname("glfwGetKeyName");

CursorPosFn raylib_cursor_callback @local;
Sample[TRAIL_MAX] trail_buffer @local;
int trail_used @local;

// raylib keeps only the last pointer position of a frame. Fast strokes need all of them.
fn void on_cursor(void* window, double x, double y) @local
{
	raylib_cursor_callback(window, x, y);
	if (trail_used < TRAIL_MAX) trail_buffer[trail_used++] = { { (float)x, (float)y }, rl::get_time() };
}

fn void hook_pointer_trail()
{
	raylib_cursor_callback = glfw_set_cursor_pos_callback(rl::get_window_handle(), &on_cursor);
}

fn void read_letters(Input* in) @local
{
	in.letters = {};
	in.first_letters = {};
	for (int key = (int)RLKeyboardKey.A; key <= (int)RLKeyboardKey.Z; key++)
	{
		if (!in.pressed[key]) continue;
		// GLFW names keys by physical position. Ask for the active layout, so that
		// Ctrl+Z is the key labelled Z on a QWERTZ keyboard too.
		ZString name = glfw_get_key_name(key, 0);
		char letter = name ? name[0] : 0;
		if (letter >= 'A' && letter <= 'Z') letter += 'a' - 'A';
		bool latin = letter >= 'a' && letter <= 'z' && name[1] == 0;
		int index = latin ? letter - 'a' : key - (int)RLKeyboardKey.A;
		in.letters[index] = true;
		if (in.first_press[key]) in.first_letters[index] = true;
	}
}

fn void read(Input* in)
{
	in.mouse = rl::get_mouse_position();
	in.delta = rl::get_mouse_delta();
	in.left_down = rl::is_mouse_button_down(LEFT);
	in.left_pressed = rl::is_mouse_button_pressed(LEFT);
	in.left_released = rl::is_mouse_button_released(LEFT);
	in.pan_pressed = rl::is_mouse_button_pressed(MIDDLE) || rl::is_mouse_button_pressed(RIGHT);
	in.pan_down = rl::is_mouse_button_down(MIDDLE) || rl::is_mouse_button_down(RIGHT);
	in.wheel = rl::get_mouse_wheel_move();
	in.ctrl = rl::is_key_down(LEFT_CONTROL) || rl::is_key_down(RIGHT_CONTROL);
	in.shift = rl::is_key_down(LEFT_SHIFT) || rl::is_key_down(RIGHT_SHIFT);
	for (int key = 32; key < KEY_COUNT; key++)
	{
		RLKeyboardKey k = (RLKeyboardKey)key;
		in.first_press[key] = rl::is_key_pressed(k);
		in.pressed[key] = in.first_press[key] || rl::is_key_pressed_repeat(k);
		in.down[key] = rl::is_key_down(k);
	}
	read_letters(in);
	in.char_count = 0;
	while (in.char_count < in.chars.len)
	{
		int c = rl::get_char_pressed();
		if (!c) break;
		in.chars[in.char_count++] = c;
	}
	in.trail_count = trail_used;
	in.trail[:trail_used] = trail_buffer[:trail_used];
	trail_used = 0;
	in.time = rl::get_time();
	in.dt = rl::get_frame_time();
	in.width = rl::get_screen_width();
	in.height = rl::get_screen_height();
}

fn bool Input.key(&self, RLKeyboardKey key) => self.pressed[(int)key];
fn bool Input.tapped(&self, RLKeyboardKey key) => self.first_press[(int)key];
fn bool Input.held(&self, RLKeyboardKey key) => self.down[(int)key];
fn bool Input.letter(&self, char c) => self.letters[c - 'a'];
fn bool Input.letter_tapped(&self, char c) => self.first_letters[c - 'a'];
