#!/usr/bin/env python3
import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from kitty_graphics import emit_png


class KittyGraphicsEmitTests(unittest.TestCase):
    def test_default_moves_cursor_by_omitting_no_move_flag(self):
        out = io.StringIO()

        emit_png(b"png", cols=4, rows=2, wispterm_fallback=False, stream=out)

        control = out.getvalue().split(";", 1)[0]
        self.assertIn("a=T", control)
        self.assertIn("c=4", control)
        self.assertIn("r=2", control)
        self.assertNotIn("C=1", control)

    def test_no_move_cursor_sets_kitty_no_move_flag(self):
        out = io.StringIO()

        emit_png(b"png", move_cursor=False, wispterm_fallback=False, stream=out)

        control = out.getvalue().split(";", 1)[0]
        self.assertIn("C=1", control)

    def test_chunk_continuations_only_set_more_flag(self):
        out = io.StringIO()

        emit_png(b"x" * 5000, image_id=7, wispterm_fallback=False, stream=out)

        commands = [part for part in out.getvalue().split("\x1b\\") if part]
        self.assertEqual(2, len(commands))
        self.assertIn("i=7", commands[0].split(";", 1)[0])
        self.assertIn("m=1", commands[0].split(";", 1)[0])
        self.assertEqual("\x1b_Gm=0", commands[1].split(";", 1)[0])

    def test_default_emits_wispterm_osc_fallback(self):
        out = io.StringIO()

        emit_png(b"png", image_id=9, stream=out)

        self.assertIn("\x1b]7747;WispTermImage=a=T", out.getvalue())
        self.assertIn("i=9", out.getvalue())


if __name__ == "__main__":
    unittest.main()
