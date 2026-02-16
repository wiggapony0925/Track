
import unittest
import sys
import os

# Add app to path
sys.path.append(os.getcwd())
from app.utils.transit_utils import get_subway_color

class TestTransitColors(unittest.TestCase):
    def test_subway_colors(self):
        # 1-2-3 (Red)
        self.assertEqual(get_subway_color("1"), "#EE352E")
        self.assertEqual(get_subway_color("2"), "#EE352E")
        self.assertEqual(get_subway_color("3"), "#EE352E")
        
        # 4-5-6 (Green)
        self.assertEqual(get_subway_color("4"), "#00933C")
        self.assertEqual(get_subway_color("6X"), "#00933C")

        # 7 (Purple)
        self.assertEqual(get_subway_color("7"), "#B933AD")
        self.assertEqual(get_subway_color("7X"), "#B933AD")

        # A-C-E (Blue)
        self.assertEqual(get_subway_color("A"), "#0039A6")
        self.assertEqual(get_subway_color("C"), "#0039A6")
        self.assertEqual(get_subway_color("E"), "#0039A6")

    def test_rail_colors(self):
        # LIRR Branches
        self.assertEqual(get_subway_color("Ronkonkoma Branch"), "#A626AA") # Purple
        self.assertEqual(get_subway_color("Babylon Branch"), "#00985F") # Green
        self.assertEqual(get_subway_color("Port Washington Branch"), "#C60C30") # Red
        
        # LIRR IDs (high numbers)
        self.assertEqual(get_subway_color("10"), "#006EC7") # Port Jeff Blue
        self.assertEqual(get_subway_color("11"), "#60269E") # Belmont Purple
        
        # Metro-North Lines
        self.assertEqual(get_subway_color("New Haven Line"), "#E00034") # Red
        self.assertEqual(get_subway_color("Hudson Line"), "#009B3A") # Green
        self.assertEqual(get_subway_color("Harlem Line"), "#0039A6") # Blue

if __name__ == '__main__':
    unittest.main()
