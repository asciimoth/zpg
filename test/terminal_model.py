"""Small screen oracle for the supported controls, independent of zpg's tracker.

The model keeps actual cells, screen coordinates, and scrollback. Its golden
checks cover cursor and screen effects before it is used for differential tests.
It deliberately rejects unknown sequences instead of silently ignoring them.
"""
import codecs
import unicodedata


class Terminal:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.screen = [[' '] * cols for _ in range(rows)]
        self.history = []
        self.overlay = [False] * rows
        self.history_overlay = []
        self.drawing = False
        self.row = self.col = 0
        self.wrap = False
        self.saved = None
        self.sgr = ()
        self.state = 'text'
        self.sequence = ''
        self.osc = False
        self.decoder = codecs.getincrementaldecoder('utf-8')('strict')
        self.snapshots = []
        self.frames = 0

    def lines(self):
        return self.history + [''.join(line).rstrip() for line in self.screen]

    def down(self):
        if self.row == self.rows - 1:
            self.history.append(''.join(self.screen.pop(0)).rstrip())
            self.history_overlay.append(self.overlay.pop(0))
            self.overlay.append(False)
            self.screen.append([' '] * self.cols)
        else:
            self.row += 1

    def save(self):
        self.saved = self.row, self.col, self.wrap, self.sgr

    def restore(self):
        if self.saved is not None:
            self.row, self.col, self.wrap, self.sgr = self.saved

    def control(self, char):
        if char == '\r':
            self.col = 0
        elif char in '\n\v\f':
            self.down()
        elif char == '\b':
            self.col = max(0, self.col - 1)
        elif char == '\t':
            self.col = min(self.cols - 1, (self.col // 8 + 1) * 8)
        else:
            return
        self.wrap = False

    def csi(self, final):
        param = self.sequence
        if final in 'hl' and param == '?2026':
            self.drawing = final == 'h'
            if final == 'l':
                self.frames += 1
                self.snapshots.append(self.lines())
            return
        assert not param or all(c in '0123456789;' for c in param), (param, final)
        values = [int(value or '0') for value in param.split(';')]
        n = values[0] or 1
        if final in 'ABCD EFG'.replace(' ', ''):
            if final == 'A':
                self.row = max(0, self.row - n)
            elif final == 'B':
                self.row = min(self.rows - 1, self.row + n)
            elif final == 'C':
                self.col = min(self.cols - 1, self.col + n)
            elif final == 'D':
                self.col = max(0, self.col - n)
            elif final == 'E':
                self.row, self.col = min(self.rows - 1, self.row + n), 0
            elif final == 'F':
                self.row, self.col = max(0, self.row - n), 0
            elif final == 'G':
                self.col = min(self.cols - 1, n - 1)
            self.wrap = False
        elif final in 'JK':
            mode = values[0]
            assert mode in (0, 1, 2), (param, final)
            start, end = (self.col, self.cols) if mode == 0 else ((0, self.col + 1) if mode == 1 else (0, self.cols))
            self.screen[self.row][start:end] = [' '] * (end - start)
            if start == 0 and end == self.cols:
                self.overlay[self.row] = False
            if final == 'J':
                for row in range(self.rows):
                    if mode == 2 or (mode == 0 and row > self.row) or (mode == 1 and row < self.row):
                        self.screen[row] = [' '] * self.cols
                        self.overlay[row] = False
            if mode == 0 or (final == 'J' and mode == 2):
                self.wrap = False
        elif final == 'm':
            self.sgr = () if values == [0] else tuple(values)
        elif final == 's':
            self.save()
        elif final == 'u':
            self.restore()
        else:
            raise AssertionError(('unknown CSI', param, final))

    def feed(self, data):
        # Decode bytes one at a time so a display inserted inside a UTF-8
        # character fails, even if the complete capture is later replayed.
        for byte in data:
            for char in self.decoder.decode(bytes([byte])):
                self.character(char)

    def character(self, char):
        if self.state in ('string', 'string_escape'):
            if (self.state == 'string_escape' and char == '\\') or (self.osc and char == '\a'):
                self.state = 'text'
            else:
                self.state = 'string_escape' if char == '\x1b' else 'string'
            return
        if char in ('\x18', '\x1a'):
            self.state = 'text'
            return
        if char == '\x1b':
            self.state = 'escape'
            return
        if ord(char) < 32:
            self.control(char)
            return
        if self.state == 'escape':
            self.state = 'text'
            if char == '[':
                self.state, self.sequence = 'csi', ''
            elif char in ']P^_X':
                self.state, self.osc = 'string', char == ']'
            elif char == '7':
                self.save()
            elif char == '8':
                self.restore()
            elif char in 'DE':
                self.down()
                if char == 'E':
                    self.col = 0
                self.wrap = False
            elif char == 'M':
                if self.row:
                    self.row -= 1
                else:
                    self.screen.pop()
                    self.screen.insert(0, [' '] * self.cols)
                    self.overlay.pop()
                    self.overlay.insert(0, False)
                self.wrap = False
            else:
                raise AssertionError(('unknown ESC', char))
            return
        if self.state == 'csi':
            if '@' <= char <= '~':
                self.csi(char)
                self.state = 'text'
            else:
                self.sequence += char
            return
        if char == '\x7f':
            return
        width = 0 if unicodedata.combining(char) else (2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1)
        if width == 0:
            previous = self.col if self.wrap else self.col - 1
            if previous >= 0:
                if self.screen[self.row][previous] == '' and previous:
                    previous -= 1
                self.screen[self.row][previous] += char
            return
        if self.wrap or self.col + width > self.cols:
            self.down()
            self.col = 0
        assert width <= self.cols, 'wide glyph in a one-column terminal is not modeled'
        self.overlay[self.row] |= self.drawing
        self.screen[self.row][self.col] = char
        if width == 2:
            self.screen[self.row][self.col + 1] = ''
        self.col += width
        self.wrap = self.col == self.cols
        self.col = min(self.col, self.cols - 1)


def check_model():
    # Golden cases are literal cell results, not a comparison to zpg's parser.
    cases = [
        (b'abcd\bX', ['abXd', '', ''], (0, 3, False)),
        (b'abcd\x1b[DX', ['abXd', '', ''], (0, 3, False)),
        (b'abcd\nX', ['abcd', '   X', ''], (1, 3, True)),
        (b'abcd\x1b[BX', ['abcd', '   X', ''], (1, 3, True)),
        (b'abcd\x1b[KX', ['abcX', '', ''], (0, 3, True)),
        (b'abcdX', ['abcd', 'X', ''], (1, 1, False)),
        (b'a\r\nb\r\nc\r\nd', ['a', 'b', 'c', 'd'], (2, 1, False)),
        (b'ab\x1b7\rXY\x1b8Z\x1b8Q', ['XYQ', '', ''], (0, 3, False)),
        (b'one\r\ntwo\x1b[F\x1b[JX', ['X', '', ''], (0, 1, False)),
        (b'abcd\r\x1b[3G\x1b[1K', ['   d', '', ''], (0, 2, False)),
        (b'\x1b]ignored\aX\x1b]ignored\x1b\\Y', ['XY', '', ''], (0, 2, False)),
    ]
    for data, lines, cursor in cases:
        for split in range(len(data) + 1):
            terminal = Terminal(3, 4)
            terminal.feed(data[:split])
            terminal.feed(data[split:])
            assert terminal.lines() == lines, (data, terminal.lines(), lines)
            assert (terminal.row, terminal.col, terminal.wrap) == cursor, data
