"""Run data jobs off the GUI thread and deliver results from a GUI-owned timer."""

from concurrent.futures import ThreadPoolExecutor
from threading import Event

from PySide6 import QtCore

from caldav_store import CalendarError


class BackgroundJobs(QtCore.QObject):
    def __init__(self, parent):
        super().__init__(parent)
        self.stopping = Event()
        self._executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="calendar")
        self._pending = {}
        self._timer = QtCore.QTimer(self, interval=20)
        self._timer.timeout.connect(self._deliver_ready)

    @property
    def busy(self):
        return bool(self._pending)

    def submit(self, action, done, *, cancel_on_close=True):
        if self.stopping.is_set():
            return
        future = self._executor.submit(action)
        self._pending[future] = (done, cancel_on_close)
        self._timer.start()

    def _deliver_ready(self):
        ready = [future for future in self._pending if future.done()]
        for future in ready:
            if self.stopping.is_set():
                return
            # A callback may enter a nested event loop that delivers another ready job.
            pending = self._pending.pop(future, None)
            if pending is None:
                continue
            done, _ = pending
            try:
                result = future.result()
            except CalendarError as error:
                done(None, str(error))
            except Exception:
                done(None, "An event or calendar response could not be read. Try refreshing.")
            else:
                done(result, "")
        if not self._pending:
            self._timer.stop()

    @QtCore.Slot()
    def stop(self):
        if self.stopping.is_set():
            return
        self.stopping.set()
        self._timer.stop()
        for future, (_, cancellable) in self._pending.items():
            if cancellable:
                future.cancel()
        self._pending.clear()
        # A bounded network request may finish after the window closes. It owns no Qt objects.
        # Already-requested writes can finish, but they can no longer call back into the window.
        self._executor.shutdown(wait=False)
