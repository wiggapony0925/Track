from __future__ import annotations

import os
import sys
import unittest

# Add app to path
sys.path.append(os.getcwd())
from app.utils.transit_utils import get_subway_color


class TestTransitColors(unittest.TestCase):
    def test_subway_colors(self):
        # 1-2-3 (Red)
        self.assertEqual(get_subway_color("1"), "#D82233")
        self.assertEqual(get_subway_color("2"), "#D82233")
        self.assertEqual(get_subway_color("3"), "#D82233")

        # 4-5-6 (Dark Green)
        self.assertEqual(get_subway_color("4"), "#009952")
        self.assertEqual(get_subway_color("6X"), "#009952")

        # 7 (Purple)
        self.assertEqual(get_subway_color("7"), "#9A38A1")
        self.assertEqual(get_subway_color("7X"), "#9A38A1")

        # A-C-E (Blue)
        self.assertEqual(get_subway_color("A"), "#0062CF")
        self.assertEqual(get_subway_color("C"), "#0062CF")
        self.assertEqual(get_subway_color("E"), "#0062CF")

    def test_rail_colors(self):
        # LIRR Branches
        self.assertEqual(get_subway_color("Ronkonkoma Branch"), "#A626AA")  # Purple
        self.assertEqual(get_subway_color("Babylon Branch"), "#00985F")  # Green
        self.assertEqual(get_subway_color("Port Washington Branch"), "#C60C30")  # Red

        # LIRR IDs (high numbers)
        self.assertEqual(get_subway_color("10"), "#006EC7")  # Port Jeff Blue
        self.assertEqual(get_subway_color("11"), "#60269E")  # Belmont Purple

        # Metro-North Lines
        self.assertEqual(get_subway_color("New Haven Line"), "#E00034")  # Red (MTA official)
        self.assertEqual(get_subway_color("Hudson Line"), "#009B3A")  # Green
        self.assertEqual(get_subway_color("Harlem Line"), "#0039A6")  # Blue


if __name__ == "__main__":
    unittest.main()
