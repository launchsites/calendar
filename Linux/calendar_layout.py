"""Calculate timeline geometry in a persistent Swift process without blocking Qt."""

import json
from collections import OrderedDict

from PySide6 import QtCore


class LayoutBridge(QtCore.QObject):
    updated = QtCore.Signal()
    engine_error = "Calendar’s shared engine could not run. Run Scripts/setup-linux again."

    def __init__(self, binary, parent):
        super().__init__(parent)
        self.process = QtCore.QProcess(self, program=str(binary), arguments=["--stream"])
        self.process.started.connect(self._send)
        self.process.readyReadStandardOutput.connect(self._read)
        self.process.readyReadStandardError.connect(self.process.readAllStandardError)
        self.process.errorOccurred.connect(self._process_error)
        self.process.finished.connect(self._finished)
        self.deadline = QtCore.QTimer(self, interval=5000, singleShot=True)
        self.deadline.timeout.connect(self.process.kill)
        self.cache = OrderedDict()
        self.latest = None
        self.active = None
        self.output = bytearray()
        self.closed = False

    @property
    def busy(self):
        return self.latest is not None and self.latest not in self.cache

    def result(self, payload):
        key = json.dumps(payload, separators=(",", ":")).encode()
        self.latest = key
        if key in self.cache:
            self.cache.move_to_end(key)
            return self.cache[key]
        self._send()
        return None

    def _send(self):
        if self.closed or self.active is not None or not self.busy:
            return
        state = self.process.state()
        if state == QtCore.QProcess.ProcessState.NotRunning:
            self.process.start()
        elif state == QtCore.QProcess.ProcessState.Running:
            self.active = self.latest
            self.deadline.start()
            self.process.write(self.active + b"\n")

    def _read(self):
        output = bytes(self.process.readAllStandardOutput())
        if self.closed or self.active is None:
            return
        self.output.extend(output)
        if b"\n" not in self.output:
            return
        try:
            response = json.loads(self.output)
            result = (response["value"], "") if "value" in response else (None, response["error"])
        except (ValueError, KeyError, TypeError):
            result = (None, self.engine_error)
        self._complete(self.active, result)
        self._send()

    def _complete(self, key, result):
        self.deadline.stop()
        self.active = None
        self.output.clear()
        if key is None:
            return
        if len(self.cache) >= 6:
            self.cache.popitem(last=False)
        self.cache[key] = result
        if key == self.latest:
            self.updated.emit()

    def _process_error(self, error):
        if not self.closed and error == QtCore.QProcess.ProcessError.FailedToStart:
            self._complete(self.latest, (None, self.engine_error))

    def _finished(self):
        if not self.closed:
            self._complete(self.active, (None, self.engine_error))
            self._send()

    def stop(self):
        self.closed = True
        self.deadline.stop()
        if self.process.state() != QtCore.QProcess.ProcessState.NotRunning:
            self.process.kill()
            self.process.waitForFinished(1000)
