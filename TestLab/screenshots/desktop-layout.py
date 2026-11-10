"""Place the demo windows inside the RDP desktop, with room on every edge."""
import ctypes as c

x = c.CDLL("libX11.so.6")
x.XOpenDisplay.restype = c.c_void_p
x.XDefaultRootWindow.argtypes = [c.c_void_p]
x.XDefaultRootWindow.restype = c.c_ulong
x.XInternAtom.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
x.XInternAtom.restype = c.c_ulong
x.XGetWindowProperty.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_long,
                                c.c_long, c.c_int, c.c_ulong,
                                c.POINTER(c.c_ulong), c.POINTER(c.c_int),
                                c.POINTER(c.c_ulong), c.POINTER(c.c_ulong),
                                c.POINTER(c.POINTER(c.c_ubyte))]
x.XFetchName.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_char_p)]
x.XMoveResizeWindow.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_int,
                               c.c_uint, c.c_uint]
x.XSync.argtypes = [c.c_void_p, c.c_int]
x.XFree.argtypes = [c.c_void_p]
x.XCloseDisplay.argtypes = [c.c_void_p]

display = x.XOpenDisplay(None)
if not display:
    raise SystemExit("Cannot open the demo display")
root = x.XDefaultRootWindow(display)
actual_type, count, remaining = c.c_ulong(), c.c_ulong(), c.c_ulong()
actual_format = c.c_int()
data = c.POINTER(c.c_ubyte)()
x.XGetWindowProperty(display, root, x.XInternAtom(display, b"_NET_CLIENT_LIST", 0),
                     0, 1024, 0, 0, c.byref(actual_type), c.byref(actual_format),
                     c.byref(count), c.byref(remaining), c.byref(data))
windows = c.cast(data, c.POINTER(c.c_ulong))
for i in range(count.value):
    name = c.c_char_p()
    if not x.XFetchName(display, windows[i], c.byref(name)) or not name.value:
        continue
    title = name.value.decode(errors="replace")
    x.XFree(name)
    if "Thunar" in title:
        x.XMoveResizeWindow(display, windows[i], 50, 100, 1260, 960)
    elif "Terminal" in title:
        x.XMoveResizeWindow(display, windows[i], 820, 850, 1100, 420)
x.XFree(data)
x.XSync(display, 0)
x.XCloseDisplay(display)
