#include "Carbon/Carbon.h"
#include "Cocoa/Cocoa.h"
#include "aerospace.h"
#include "config.h"
#import "event_tap.h"
#include "haptic.h"
#include <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <pthread.h>

static aerospace* g_aerospace = NULL;
static CFTypeRef g_haptic = NULL;
static Config g_config;
static pthread_mutex_t g_gesture_mutex = PTHREAD_MUTEX_INITIALIZER;
static gesture_ctx g_gesture_ctx = { 0 };
static CFMutableDictionaryRef g_tracks = NULL;
static BOOL g_enabled = YES;

// Menu bar app delegate
@interface AppDelegate : NSObject <NSApplicationDelegate> {
    NSMenuItem *_sensitivityItems[3];
    NSMenuItem *_fingerItems[3];
}
@property (strong, nonatomic) NSStatusItem *statusItem;
@property (strong, nonatomic) NSMenuItem *enabledMenuItem;
@property (strong, nonatomic) NSMenuItem *hapticMenuItem;
@property (strong, nonatomic) NSMenuItem *naturalSwipeMenuItem;
@property (strong, nonatomic) NSMenuItem *wrapAroundMenuItem;
@property (strong, nonatomic) NSMenuItem *skipEmptyMenuItem;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Skip menu bar if disabled in config
    if (!g_config.show_menu_bar) {
        NSLog(@"Menu bar disabled in config");
        return;
    }

    // Create status bar item
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    // Set the icon (using SF Symbol or fallback to text)
    if (@available(macOS 11.0, *)) {
        NSImage *icon = [NSImage imageWithSystemSymbolName:@"hand.draw" accessibilityDescription:@"AeroSpace Swipe"];
        [icon setTemplate:YES];
        self.statusItem.button.image = icon;
    } else {
        self.statusItem.button.title = @"⇄";
    }
    self.statusItem.button.toolTip = @"AeroSpace Swipe";

    // Create menu
    NSMenu *menu = [[NSMenu alloc] init];

    // Enabled toggle
    self.enabledMenuItem = [[NSMenuItem alloc] initWithTitle:@"Enabled" action:@selector(toggleEnabled:) keyEquivalent:@""];
    self.enabledMenuItem.target = self;
    self.enabledMenuItem.state = NSControlStateValueOn;
    [menu addItem:self.enabledMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Sensitivity submenu
    NSMenuItem *sensitivityMenuItem = [[NSMenuItem alloc] initWithTitle:@"Sensitivity" action:nil keyEquivalent:@""];
    NSMenu *sensitivityMenu = [[NSMenu alloc] init];
    NSString *sensitivityLabels[] = {@"Low", @"Medium", @"High"};
    for (int i = 0; i < 3; i++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:sensitivityLabels[i] action:@selector(setSensitivity:) keyEquivalent:@""];
        item.target = self;
        item.tag = i + 1;
        item.state = (g_config.sensitivity == i + 1) ? NSControlStateValueOn : NSControlStateValueOff;
        [sensitivityMenu addItem:item];
        _sensitivityItems[i] = item;
    }
    sensitivityMenuItem.submenu = sensitivityMenu;
    [menu addItem:sensitivityMenuItem];

    // Fingers submenu
    NSMenuItem *fingersMenuItem = [[NSMenuItem alloc] initWithTitle:@"Fingers" action:nil keyEquivalent:@""];
    NSMenu *fingersMenu = [[NSMenu alloc] init];
    for (int i = 0; i < 3; i++) {
        int fingers = i + 2;  // 2, 3, 4
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%d fingers", fingers] action:@selector(setFingers:) keyEquivalent:@""];
        item.target = self;
        item.tag = fingers;
        item.state = (g_config.fingers == fingers) ? NSControlStateValueOn : NSControlStateValueOff;
        [fingersMenu addItem:item];
        _fingerItems[i] = item;
    }
    fingersMenuItem.submenu = fingersMenu;
    [menu addItem:fingersMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Toggle options
    self.hapticMenuItem = [[NSMenuItem alloc] initWithTitle:@"Haptic Feedback" action:@selector(toggleHaptic:) keyEquivalent:@""];
    self.hapticMenuItem.target = self;
    self.hapticMenuItem.state = g_config.haptic ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.hapticMenuItem];

    self.naturalSwipeMenuItem = [[NSMenuItem alloc] initWithTitle:@"Natural Swipe" action:@selector(toggleNaturalSwipe:) keyEquivalent:@""];
    self.naturalSwipeMenuItem.target = self;
    self.naturalSwipeMenuItem.state = g_config.natural_swipe ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.naturalSwipeMenuItem];

    self.wrapAroundMenuItem = [[NSMenuItem alloc] initWithTitle:@"Wrap Around" action:@selector(toggleWrapAround:) keyEquivalent:@""];
    self.wrapAroundMenuItem.target = self;
    self.wrapAroundMenuItem.state = g_config.wrap_around ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.wrapAroundMenuItem];

    self.skipEmptyMenuItem = [[NSMenuItem alloc] initWithTitle:@"Skip Empty" action:@selector(toggleSkipEmpty:) keyEquivalent:@""];
    self.skipEmptyMenuItem.target = self;
    self.skipEmptyMenuItem.state = g_config.skip_empty ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:self.skipEmptyMenuItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Quit
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
}

- (void)toggleEnabled:(id)sender {
    g_enabled = !g_enabled;
    self.enabledMenuItem.state = g_enabled ? NSControlStateValueOn : NSControlStateValueOff;

    if (@available(macOS 11.0, *)) {
        NSString *iconName = g_enabled ? @"hand.draw" : @"hand.raised.slash";
        NSImage *icon = [NSImage imageWithSystemSymbolName:iconName accessibilityDescription:@"AeroSpace Swipe"];
        [icon setTemplate:YES];
        self.statusItem.button.image = icon;
    }

    NSLog(@"AeroSpace Swipe %@", g_enabled ? @"enabled" : @"disabled");
}

- (void)setSensitivity:(NSMenuItem *)sender {
    int level = (int)sender.tag;
    apply_sensitivity(&g_config, level);

    // Update checkmarks (1=Low, 2=Medium, 3=High)
    for (int i = 0; i < 3; i++) {
        _sensitivityItems[i].state = (i + 1 == level) ? NSControlStateValueOn : NSControlStateValueOff;
    }

    NSLog(@"Sensitivity set to %d (distance=%.2f, fast=%.2fx@vel%.2f)",
          level, g_config.distance_pct, g_config.fast_distance_factor, g_config.fast_velocity_threshold);
}

- (void)setFingers:(NSMenuItem *)sender {
    int fingers = (int)sender.tag;
    g_config.fingers = fingers;

    // Update checkmarks
    for (int i = 0; i < 3; i++) {
        _fingerItems[i].state = (_fingerItems[i].tag == fingers) ? NSControlStateValueOn : NSControlStateValueOff;
    }

    NSLog(@"Fingers set to %d", fingers);
}

- (void)toggleHaptic:(id)sender {
    g_config.haptic = !g_config.haptic;
    self.hapticMenuItem.state = g_config.haptic ? NSControlStateValueOn : NSControlStateValueOff;

    // Initialize haptic if enabling and not already initialized
    if (g_config.haptic && !g_haptic) {
        g_haptic = haptic_open_default();
        if (!g_haptic) {
            NSLog(@"Warning: Failed to initialize haptic actuator");
        }
    }

    NSLog(@"Haptic feedback %@", g_config.haptic ? @"enabled" : @"disabled");
}

- (void)toggleNaturalSwipe:(id)sender {
    g_config.natural_swipe = !g_config.natural_swipe;
    self.naturalSwipeMenuItem.state = g_config.natural_swipe ? NSControlStateValueOn : NSControlStateValueOff;

    // Update swipe directions
    g_config.swipe_left = g_config.natural_swipe ? "next" : "prev";
    g_config.swipe_right = g_config.natural_swipe ? "prev" : "next";

    NSLog(@"Natural swipe %@", g_config.natural_swipe ? @"enabled" : @"disabled");
}

- (void)toggleWrapAround:(id)sender {
    g_config.wrap_around = !g_config.wrap_around;
    self.wrapAroundMenuItem.state = g_config.wrap_around ? NSControlStateValueOn : NSControlStateValueOff;

    NSLog(@"Wrap around %@", g_config.wrap_around ? @"enabled" : @"disabled");
}

- (void)toggleSkipEmpty:(id)sender {
    g_config.skip_empty = !g_config.skip_empty;
    self.skipEmptyMenuItem.state = g_config.skip_empty ? NSControlStateValueOn : NSControlStateValueOff;

    NSLog(@"Skip empty %@", g_config.skip_empty ? @"enabled" : @"disabled");
}

- (void)quit:(id)sender {
    [[NSApplication sharedApplication] terminate:nil];
}

@end

static void switch_workspace(const char* ws)
{
	// Ensure socket is alive; reconnect if broken or stale
	if (!aerospace_ensure_connected(g_aerospace)) {
		fprintf(stderr, "Error: Not connected to AeroSpace, will retry next swipe.\n");
		return;
	}

	if (g_config.skip_empty || g_config.wrap_around) {
		char* workspaces = aerospace_list_workspaces(g_aerospace, !g_config.skip_empty);
		if (!workspaces) {
			fprintf(stderr, "Error: Unable to retrieve workspace list.\n");
			return;
		}
		char* result = aerospace_workspace(g_aerospace, g_config.wrap_around, ws, workspaces);
		if (result) {
			fprintf(stderr, "Error: Failed to switch workspace to '%s'.\n", ws);
		} else {
			printf("Switched workspace successfully to '%s'.\n", ws);
		}
		free(workspaces);
		free(result);
	} else {
		char* result = aerospace_switch(g_aerospace, ws);
		if (result) {
			fprintf(stderr, "Error: Failed to switch workspace: '%s'\n", result);
		} else {
			printf("Switched workspace successfully to '%s'.\n", ws);
		}
		free(result);
	}

	if (g_config.haptic && g_haptic)
		haptic_actuate(g_haptic, 3);
}

static void reset_gesture_state(gesture_ctx* ctx)
{
	ctx->state = GS_IDLE;
	ctx->last_fire_dir = 0;
}

static void fire_gesture(gesture_ctx* ctx, int direction)
{
	if (direction == ctx->last_fire_dir)
		return;

	ctx->last_fire_dir = direction;
	ctx->state = GS_COMMITTED;

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		switch_workspace(direction > 0 ? g_config.swipe_right : g_config.swipe_left);
	});
}

static void calculate_touch_averages(touch* touches, int count,
	float* avg_x, float* avg_y, float* avg_vel,
	float* min_x, float* max_x, float* min_y, float* max_y)
{
	*avg_x = *avg_y = *avg_vel = 0;
	*min_x = *min_y = 1;
	*max_x = *max_y = 0;

	for (int i = 0; i < count; ++i) {
		*avg_x += touches[i].x;
		*avg_y += touches[i].y;
		*avg_vel += touches[i].velocity;

		if (touches[i].x < *min_x)
			*min_x = touches[i].x;
		if (touches[i].x > *max_x)
			*max_x = touches[i].x;
		if (touches[i].y < *min_y)
			*min_y = touches[i].y;
		if (touches[i].y > *max_y)
			*max_y = touches[i].y;
	}

	*avg_x /= count;
	*avg_y /= count;
	*avg_vel /= count;
}

static bool handle_committed_state(gesture_ctx* ctx, touch* touches, int count)
{
	bool all_ended = true;
	for (int i = 0; i < count; ++i) {
		if (touches[i].phase != END_PHASE) {
			all_ended = false;
			break;
		}
	}

	if (!count || all_ended) {
		reset_gesture_state(ctx);
		return true;
	}

	float avg_x, avg_y, avg_vel, min_x, max_x, min_y, max_y;
	calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_vel,
		&min_x, &max_x, &min_y, &max_y);

	float dx = avg_x - ctx->start_x;
	if ((dx * ctx->last_fire_dir) < 0 && fabsf(dx) >= g_config.min_travel) {
		ctx->state = GS_ARMED;
		ctx->start_x = avg_x;
		ctx->start_y = avg_y;
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;

		for (int i = 0; i < count; ++i)
			ctx->base_x[i] = touches[i].x;
	}

	return true;
}

static void handle_idle_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_vel)
{
	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float need = fast ? g_config.min_travel_fast : g_config.min_travel;

	// Count how many fingers have moved enough (allow some to lag)
	int moved_count = 0;
	for (int i = 0; i < count; ++i) {
		if (fabsf(touches[i].x - ctx->base_x[i]) >= need)
			moved_count++;
	}
	// At least half the fingers should have moved
	bool moved = (moved_count >= (count + 1) / 2);

	float dx = avg_x - ctx->start_x;
	float dy = avg_y - ctx->start_y;

	// Arm if moved and horizontal movement dominates
	if (moved && (fast || fabsf(dx) >= ACTIVATE_PCT || fabsf(avg_vel) >= g_config.velocity_pct * 0.5f)) {
		// Horizontal must be greater than vertical (original behavior)
		if (fabsf(dx) > fabsf(dy) || fast) {
			ctx->state = GS_ARMED;
			ctx->start_x = avg_x;
			ctx->start_y = avg_y;
			ctx->peak_velx = avg_vel;
			ctx->dir = (avg_vel >= 0) ? 1 : -1;
		}
	}
}

static void handle_armed_state(gesture_ctx* ctx, touch* touches, int count,
	float avg_x, float avg_y, float avg_vel)
{
	float dx = avg_x - ctx->start_x;
	float dy = avg_y - ctx->start_y;

	// Reset if vertical movement exceeds horizontal (with small tolerance for diagonal)
	if (fabsf(dy) > fabsf(dx) * 1.2f) {
		reset_gesture_state(ctx);
		return;
	}

	bool fast = fabsf(avg_vel) >= g_config.velocity_pct * FAST_VEL_FACTOR;
	float stepReq = fast ? g_config.min_step_fast : g_config.min_step;

	int mismatch_count = 0;
	for (int i = 0; i < count; ++i) {
		float ddx = touches[i].x - ctx->prev_x[i];
		if (fabsf(ddx) < stepReq || (ddx * dx) < 0) {
			mismatch_count++;
			if (mismatch_count > g_config.swipe_tolerance) {
				reset_gesture_state(ctx);
				return;
			}
		}
	}

	if (fabsf(avg_vel) > fabsf(ctx->peak_velx)) {
		ctx->peak_velx = avg_vel;
		ctx->dir = (avg_vel >= 0) ? 1 : -1;
	}

	// Fire based on distance
	if (fabsf(dx) >= g_config.distance_pct) {
		fire_gesture(ctx, dx > 0 ? 1 : -1);
	}
	// Or fire on fast intentional swipes (for medium/high sensitivity)
	// Must reach at least fast_distance_factor of the threshold distance
	else if (fabsf(avg_vel) >= g_config.fast_velocity_threshold &&
	         fabsf(dx) >= g_config.distance_pct * g_config.fast_distance_factor) {
		fire_gesture(ctx, dx > 0 ? 1 : -1);
	}
}

static void gestureCallback(touch* touches, int count)
{
	if (!g_enabled)
		return;

	pthread_mutex_lock(&g_gesture_mutex);

	gesture_ctx* ctx = &g_gesture_ctx;

	if (ctx->state == GS_COMMITTED) {
		if (handle_committed_state(ctx, touches, count))
			goto unlock;
	}

	if (count != g_config.fingers) {
		if (ctx->state == GS_ARMED)
			ctx->state = GS_IDLE;

		for (int i = 0; i < count; ++i)
			ctx->prev_x[i] = ctx->base_x[i] = touches[i].x;

		goto unlock;
	}

	float avg_x, avg_y, avg_vel, min_x, max_x, min_y, max_y;
	calculate_touch_averages(touches, count, &avg_x, &avg_y, &avg_vel,
		&min_x, &max_x, &min_y, &max_y);

	if (ctx->state == GS_IDLE) {
		handle_idle_state(ctx, touches, count, avg_x, avg_y, avg_vel);
	} else if (ctx->state == GS_ARMED) {
		handle_armed_state(ctx, touches, count, avg_x, avg_y, avg_vel);
	}

	for (int i = 0; i < count; ++i) {
		ctx->prev_x[i] = touches[i].x;
		if (ctx->state == GS_IDLE)
			ctx->base_x[i] = touches[i].x;
	}

unlock:
	pthread_mutex_unlock(&g_gesture_mutex);
}

static void process_touches(NSSet<NSTouch*>* touches)
{
	NSUInteger buf_capacity = touches.count > 0 ? touches.count : 4;
	touch* buf = malloc(sizeof(touch) * buf_capacity);
	NSUInteger i = 0;

	for (NSTouch* touch in touches) {
		if (touch.phase != (1 << 2)) {
			if (i >= buf_capacity) {
				buf_capacity *= 2;
				buf = realloc(buf, sizeof(touch) * buf_capacity);
			}
			buf[i++] = [TouchConverter convert_nstouch:touch];
		}
	}

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		gestureCallback(buf, (int)i);
		free(buf);
	});
}

static CGEventRef key_handler(__unused CGEventTapProxy proxy, CGEventType type,
	CGEventRef event, void* ref)
{
	struct event_tap* event_tap_ref = (struct event_tap*)ref;

	if (!AXIsProcessTrusted()) {
		NSLog(@"Accessibility permission lost, disabling tap.");
		event_tap_end(event_tap_ref);
		return event;
	}

	if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
		NSLog(@"Event-tap re-enabled.");
		CGEventTapEnable(event_tap_ref->handle, true);
		return event;
	}

	if (type != NSEventTypeGesture)
		return event;

	NSEvent* ev = [NSEvent eventWithCGEvent:event];
	NSSet<NSTouch*>* touches = ev.allTouches;

	if (!touches.count)
		return event;

	process_touches(touches);

	return event;
}

static void acquire_lockfile(void)
{
	char* user = getenv("USER");
	if (!user)
		printf("Error: User variable not set.\n"), exit(1);

	char buffer[256];
	snprintf(buffer, 256, "/tmp/aerospace-swipe-%s.lock", user);

	int handle = open(buffer, O_CREAT | O_WRONLY, 0600);
	if (handle == -1) {
		printf("Error: Could not create lock-file.\n");
		exit(1);
	}

	struct flock lockfd = {
		.l_start = 0,
		.l_len = 0,
		.l_pid = getpid(),
		.l_type = F_WRLCK,
		.l_whence = SEEK_SET
	};

	if (fcntl(handle, F_SETLK, &lockfd) == -1) {
		printf("Error: Could not acquire lock-file.\naerospace-swipe already running?\n");
		exit(1);
	}
}

void waitForAccessibilityAndRestart(void)
{
	while (!AXIsProcessTrusted()) {
		NSLog(@"Waiting for accessibility permission...");
		sleep(1);
	}

	NSLog(@"Accessibility permission granted. Restarting app...");

	NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
	[[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:bundlePath] configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
	exit(0);
}

int main(int argc, const char* argv[])
{
	signal(SIGCHLD, SIG_IGN);
	signal(SIGPIPE, SIG_IGN);

	acquire_lockfile();

	@autoreleasepool {
		NSDictionary* options = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};

		if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
			NSLog(@"Accessibility permission not granted. Prompting user...");
			AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);

			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
				waitForAccessibilityAndRestart();
			});

			CFRunLoopRun();
		}

		NSLog(@"Accessibility permission granted. Continuing app initialization...");

		g_config = load_config();
		NSLog(@"Loaded config: fingers=%d, skip_empty=%s, wrap_around=%s, haptic=%s, swipe_left='%s', swipe_right='%s'",
			g_config.fingers,
			g_config.skip_empty ? "YES" : "NO",
			g_config.wrap_around ? "YES" : "NO",
			g_config.haptic ? "YES" : "NO",
			g_config.swipe_left,
			g_config.swipe_right);

		g_aerospace = aerospace_new(NULL);
		if (!g_aerospace) {
			fprintf(stderr, "Error: Failed to allocate Aerospace client.\n");
			exit(EXIT_FAILURE);
		}
		// Socket may not connect yet (AeroSpace might not be running).
		// That's fine - aerospace_ensure_connected() will retry on each swipe.

		if (g_config.haptic) {
			g_haptic = haptic_open_default();
			if (!g_haptic)
				fprintf(stderr, "Warning: Failed to initialize haptic actuator. Continuing without haptics.\n");
		}

		g_tracks = CFDictionaryCreateMutable(NULL, 0,
			&kCFTypeDictionaryKeyCallBacks,
			NULL);

		event_tap_begin(&g_event_tap, key_handler);

		// Set up NSApplication with our delegate for menu bar
		NSApplication *app = [NSApplication sharedApplication];
		AppDelegate *delegate = [[AppDelegate alloc] init];
		app.delegate = delegate;

		// Activate as accessory (menu bar only, no dock icon)
		[app setActivationPolicy:NSApplicationActivationPolicyAccessory];

		[app run];
		return 0;
	}
}
