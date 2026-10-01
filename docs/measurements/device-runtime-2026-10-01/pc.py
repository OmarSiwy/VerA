"""User-space retired-instruction counter over this process and every child it
spawns after start() (perf_event_open, inherit=1), summed over the hybrid
cpu_core and cpu_atom PMUs. Load-invariant measure of compile work."""
import ctypes, os, struct
_libc = ctypes.CDLL(None, use_errno=True)
_libc.syscall.restype = ctypes.c_long
NR = 298
def _pmu(name):
    try: return int(open(f"/sys/bus/event_source/devices/{name}/type").read())
    except OSError: return None
class Counter:
    def __init__(self, event=1, inherit=True):
        self.fds = []
        for pmu in ("cpu_core", "cpu_atom"):
            t = _pmu(pmu)
            if t is None: continue
            attr = bytearray(128)
            # type=HARDWARE(0), size, config = pmu<<32 | INSTRUCTIONS(1)
            struct.pack_into("<IIQ", attr, 0, 0, 128, (t << 32) | event)
            flags = (1 << 0) | (int(inherit) << 1) | (1 << 5) | (1 << 6)  # disabled, inherit, exclude_kernel, exclude_hv
            struct.pack_into("<Q", attr, 40, flags)
            buf = ctypes.create_string_buffer(bytes(attr), 128)
            fd = _libc.syscall(NR, buf, 0, -1, -1, 0)
            if fd < 0: raise OSError(ctypes.get_errno(), "perf_event_open")
            self.fds.append(fd)
    def start(self):
        for fd in self.fds: _libc.ioctl(fd, 0x2400 + 3, 0)  # RESET
        for fd in self.fds: _libc.ioctl(fd, 0x2400, 0)      # ENABLE
    def read(self):
        return sum(struct.unpack("<Q", os.read(fd, 8))[0] for fd in self.fds)
