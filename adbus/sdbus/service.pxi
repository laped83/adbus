# Copyright: 2017, CCX Technologies
#cython: language_level=3

cdef class Service:
    cdef sdbus_h.sd_bus *bus
    cdef bytes name
    cdef bytes unique_name
    cdef bool connected
    cdef stdint.uint64_t flags
    cdef object loop
    cdef int bus_fd
    cdef int events_fd

    def __cinit__(self, name=None, loop=None, bus='system',
            replace_existing=False, allow_replacement=False, queue=False):
        cdef const char *unique

        if name:
            self.name = name.encode()
        else:
            self.name = b''
        self.flags = 0
        self.connected = False
        self.loop = loop
        self.bus_fd = -1
        self.events_fd = -1

        if bus == 'system':
            if sdbus_h.sd_bus_open_system(&self.bus) < 0:
                raise BusError("Failed to connect to Bus")

        elif bus == 'session':
            if sdbus_h.sd_bus_open_user(&self.bus) < 0:
                raise BusError("Failed to connect to Bus")

        else:
            raise BusError(f"Invalid bus {bus}, expecting system of session")

        if replace_existing:
            self.flags |= sdbus_h.SD_BUS_NAME_REPLACE_EXISTING

        if allow_replacement:
            self.flags |= sdbus_h.SD_BUS_NAME_ALLOW_REPLACEMENT

        if queue:
            self.flags |= sdbus_h.SD_BUS_NAME_QUEUE

        if self.name:
            if sdbus_h.sd_bus_request_name(self.bus, self.name, self.flags) < 0:
                raise BusError(f"Failed to acquire name {self.name.decode('utf-8')}")

        if sdbus_h.sd_bus_get_unique_name(self.bus, &unique) < 0:
            raise BusError("Failed to read unique name")
        self.unique_name = unique

        if not loop:
            loop = get_event_loop()

        self.loop = loop
        self.check_fd()

    def check_fd(self):
        bus_fd = sdbus_h.sd_bus_get_fd(self.bus)
        if bus_fd < 0:
            raise("Failed to read sd-bus file descriptor")

        events_fd = sdbus_h.sd_bus_get_events(self.bus)
        if events_fd < 0:
            raise("Failed to reader sd-bus file descriptor events")

        # Remove callbacks ff current file descriptor or events doesn't match
        if self.bus_fd != bus_fd or self.events_fd != events_fd:
            # Don't remove old callback if just initialized
            if self.bus_fd != -1:
                self.loop.remove_writer(self.bus_fd)
                self.loop.remove_reader(self.bus_fd)
            # Add writer callback if events_fd isn't 1
            if events_fd != 1:
                self.loop.add_writer(bus_fd, self.process)
            else:
                self.loop.add_reader(bus_fd, self.process)
        # Save current bus and events for file descriptor
        self.bus_fd = bus_fd
        self.events_fd = events_fd

    def is_running(self):
        """Service is running."""
        return self.loop.is_running()

    def get_loop(self):
        """Get the service's asyncio loop."""
        return self.loop

    def __dealloc__(self):
        self.bus = sdbus_h.sd_bus_unref(self.bus)

    def process(self):
        """Processes all available transactions from the D-Bus.

        Raises:
            sdbus.BusError: if an error occurs interfacing with the D-Bus
            Exception: re-raised if raised by any callbacks, or property setters
        """

        if self.connected:
            raise BusError(f"Already processing")

        self.connected = True
        try:
            while True:
                r = sdbus_h.sd_bus_process(self.bus, NULL)

                if r < 0:
                    raise BusError(f"D-Bus Process Error: {errorcode[-r]}")

                if r == 0:
                    break

            self.check_fd()
        finally:
            self.connected = False
