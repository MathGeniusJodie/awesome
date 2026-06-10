/*
 * scrollpipe — stream horizontal smooth-scroll deltas from XInput2 raw
 * events to stdout, for pixel-smooth canvas scrolling in splitwm.
 *
 * Output, one line each, flushed immediately:
 *   "# devices N"   on start and whenever the device list changes
 *                   (N = devices with a horizontal scroll valuator)
 *   "<float>"       scroll delta in wheel-click fractions (value/increment)
 *
 * Build: gcc -O2 -o scrollpipe scrollpipe.c -lX11 -lXi
 */
#include <stdio.h>
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>

#define MAX_DEVS 256

typedef struct {
    int dev;        /* slave device id (raw events carry it in sourceid) */
    int valuator;   /* valuator number of the horizontal scroll axis */
    double incr;    /* valuator units per wheel click */
} HScroll;

static HScroll map[MAX_DEVS];
static int nmap = 0;

static void build_map(Display *dpy)
{
    int n;
    XIDeviceInfo *info = XIQueryDevice(dpy, XIAllDevices, &n);
    nmap = 0;
    for (int i = 0; i < n && nmap < MAX_DEVS; i++) {
        for (int j = 0; j < info[i].num_classes; j++) {
            if (info[i].classes[j]->type != XIScrollClass)
                continue;
            XIScrollClassInfo *sc = (XIScrollClassInfo *)info[i].classes[j];
            if (sc->scroll_type == XIScrollTypeHorizontal) {
                map[nmap].dev      = info[i].deviceid;
                map[nmap].valuator = sc->number;
                map[nmap].incr     = sc->increment != 0 ? sc->increment : 120.0;
                nmap++;
            }
        }
    }
    XIFreeDeviceInfo(info);
    printf("# devices %d\n", nmap);
    fflush(stdout);
}

int main(void)
{
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy)
        return 1;

    int xi_opcode, ev, err;
    if (!XQueryExtension(dpy, "XInputExtension", &xi_opcode, &ev, &err))
        return 1;
    int major = 2, minor = 1;
    if (XIQueryVersion(dpy, &major, &minor) != Success)
        return 1;

    build_map(dpy);

    unsigned char m[XIMaskLen(XI_LASTEVENT)] = { 0 };
    XIEventMask mask = {
        .deviceid = XIAllMasterDevices,
        .mask_len = sizeof(m),
        .mask     = m,
    };
    XISetMask(m, XI_RawMotion);
    XISelectEvents(dpy, DefaultRootWindow(dpy), &mask, 1);

    /* Device hotplug: re-scan scroll axes when the hierarchy changes. */
    unsigned char hm[XIMaskLen(XI_LASTEVENT)] = { 0 };
    XIEventMask hmask = {
        .deviceid = XIAllDevices,
        .mask_len = sizeof(hm),
        .mask     = hm,
    };
    XISetMask(hm, XI_HierarchyChanged);
    XISelectEvents(dpy, DefaultRootWindow(dpy), &hmask, 1);
    XFlush(dpy);

    for (;;) {
        XEvent e;
        XNextEvent(dpy, &e);
        XGenericEventCookie *c = &e.xcookie;
        if (c->type != GenericEvent || c->extension != xi_opcode)
            continue;
        if (!XGetEventData(dpy, c))
            continue;

        if (c->evtype == XI_HierarchyChanged) {
            build_map(dpy);
        } else if (c->evtype == XI_RawMotion) {
            XIRawEvent *re = (XIRawEvent *)c->data;
            for (int k = 0; k < nmap; k++) {
                if (map[k].dev != re->sourceid)
                    continue;
                if (!XIMaskIsSet(re->valuators.mask, map[k].valuator))
                    continue;
                /* Position of our valuator among the set bits. */
                int idx = 0;
                for (int b = 0; b < map[k].valuator; b++)
                    if (XIMaskIsSet(re->valuators.mask, b))
                        idx++;
                printf("%.4f\n", re->valuators.values[idx] / map[k].incr);
                fflush(stdout);
            }
        }
        XFreeEventData(dpy, c);
    }
}
