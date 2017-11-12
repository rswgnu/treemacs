from subprocess import Popen, PIPE
import sys

RECURSIVE = len(sys.argv) > 1
GIT_CMD   = "git status --porcelain --ignored " + ("-uall" if RECURSIVE else ".")
STDOUT    = sys.stdout

def run(cmd):
    call = Popen(cmd, shell=True, stdout=PIPE)
    return call.communicate()[0].strip().decode('utf-8')

call_result = run(GIT_CMD).split("\n")

STDOUT.write('(')
for item in call_result:
    state, filename = item.split(' ', 1)
    STDOUT.write('("' + state + '" . "' + filename + '")')
STDOUT.write(')')
