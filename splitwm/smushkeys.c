#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <string.h>
#include <unistd.h>

static void chord(Display *display, unsigned int ctrl, unsigned int key)
{
    XTestFakeKeyEvent(display, ctrl, True, 0);
    XTestFakeKeyEvent(display, key, True, 0);
    XTestFakeKeyEvent(display, key, False, 0);
    XTestFakeKeyEvent(display, ctrl, False, 0);
    XFlush(display);
    usleep(25000);
}

int main(int argc, char **argv)
{
    Display *display = XOpenDisplay(NULL);
    if (!display) return 1;

    unsigned int ctrl = XKeysymToKeycode(display, XK_Control_L);
    unsigned int zero = XKeysymToKeycode(display, XK_0);
    unsigned int minus = XKeysymToKeycode(display, XK_minus);
    if (!ctrl || !zero || !minus) {
        XCloseDisplay(display);
        return 1;
    }

    chord(display, ctrl, zero);
    if (argc >= 2 && strcmp(argv[1], "tiny") == 0) {
        chord(display, ctrl, minus);
        chord(display, ctrl, minus);
    } else if (argc < 2 || strcmp(argv[1], "reset") != 0) {
        chord(display, ctrl, minus);
    }

    XCloseDisplay(display);
    return 0;
}
