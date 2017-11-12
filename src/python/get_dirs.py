from os import listdir
from os.path import join, isfile, abspath, isdir, splitext
import sys
import os

DIR = abspath(sys.argv[1])
OUT = sys.stdout

files = []
dirs = []
# exts = {
#     ".el"  : "treemacs-icon-emacs",
#     ".py"  : "treemacs-icon-python",
#     ".png" : "treemacs-icon-image",
# }

for item in listdir(DIR):
    abs_path = join(DIR, item)
    if  os.access(abs_path, os.R_OK) and item[0] != '.':
        if isfile(abs_path):
            # ext = splitext(item)[1]
            # img = exts.get(ext, "treemacs-icon-text")
            files.append("\"" + abs_path + "\"")
        else:
            dirs.append("\"" + abs_path + "\"")

OUT.write("((" + " ".join(files) + ")")
OUT.write("(" + " ".join(dirs) + ")")
OUT.write("))")
