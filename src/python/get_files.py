from os import listdir
from os.path import join, isfile, abspath
import sys
import os

DIR = abspath(sys.argv[1])
OUT = sys.stdout

files = []
for item in listdir(DIR):
    abs_path = join(DIR, item)
    if isfile(abs_path) and os.access(abs_path, os.R_OK) and item[0] != '.':
        files.append("\"" + abs_path + "\"")

OUT.write("(")
OUT.write(" ".join(files))
OUT.write(")")
